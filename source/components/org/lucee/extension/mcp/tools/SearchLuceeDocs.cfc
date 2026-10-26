/**
 * MCP Tool: search_lucee_docs
 *
 * Searches Lucee documentation (functions, tags and recipes) using Lucene
 * full-text search and returns the most relevant passages as context.
 *
 * Requires the Lucee Lucene 3 extension (EFDEB172-F52E-4D84-9CD1A1F561B3DFC8).
 * If the extension is not installed the tool returns a graceful message.
 *
 * The search index is kept on disk and only checked for changes once per cache TTL
 * (default 3600 seconds). Configure the TTL in seconds with the system property
 * "lucee.mcp.search.ttl" or the environment variable "LUCEE_MCP_SEARCH_TTL";
 * 0 checks the sources on every call. When the TTL expires and an index already exists,
 * the check runs in a background thread and searches keep using the existing index.
 * If the recipe source can't be reached, the recipes already indexed are kept.
 */
component extends="Tool" {

	variables.name        = "search_lucee_docs";
	variables.description = "Search Lucee documentation across functions, tags and recipes. "
	                      & "Returns the most relevant documentation passages for a given query. "
	                      & "Use this when you need to look up how something works in Lucee CFML.";

	variables.inputSchema = {
		"type"      : "object",
		"properties": {
			"query": {
				"type"       : "string",
				"description": "The search query, e.g. 'how to read a file', 'arraySort', 'cfquery tag'"
			},
			"maxResults": {
				"type"       : "integer",
				"description": "Maximum number of results to return (default: 3, max: 10)",
				"default"    : 3
			}
		},
		"required": [ "query" ]
	};

	// Lucene extension UUID
	static.LUCENE_EXT_ID   = "EFDEB172-F52E-4D84-9CD1A1F561B3DFC8";
	static.COLLECTION_NAME = "luceeai";

	// index cache
	static.DEFAULT_TTL     = 3600; // seconds
	static.RETRY_AFTER     = 300;  // seconds, max. wait before a failed source check is retried
	static.STATE_KEY       = "luceeMcpSearchIndexState";
	static.LOCK_NAME       = "lucee-mcp-search-index";

	// -------------------------------------------------------------------------

	public function exec( required struct args ) {
		if ( !structKeyExists( args, "query" ) || isEmpty( trim( args.query ) ) ) {
			cfthrow( message: "query is required" );
		}

		if ( !searchSupported() ) {
			return toTextContent( "Search is not available: Lucene 3 extension is not installed." );
		}

		var query      = trim( args.query );
		var maxResults = min( val( args.maxResults ?: 3 ), 10 );
		if ( maxResults < 1 ) maxResults = 3;

		ensureIndex();

		// Escape Lucene special characters
		var safeQuery = reReplace( query, "([+\-&|!(){}[\]^""~*?:\\/])", "\\\1", "ALL" );

		cfsearch(
			contextpassages      = 3
			contextHighlightBegin= ""
			contextHighlightEnd  = ""
			contextBytes         = 3000
			contextpassageLength = 1000
			name                 = "local.results"
			collection           = static.COLLECTION_NAME
			criteria             = safeQuery
			suggestions          = "always"
			maxrows              = maxResults
		);

		if ( results.recordCount == 0 ) {
			return toTextContent( "No documentation found for: #query#" );
		}

		var output = [];
		loop query=results {
			var passages = [];
			if ( listFindNoCase( results.columnList, "context" ) && len( trim( toString( results.context ) ) ) ) {
				arrayAppend( passages, { "data": toString( results.context ) } );
			}

			var src = results.custom2;
			src = replace( src,
				"https://raw.githubusercontent.com/lucee/lucee-docs/master/",
				"https://github.com/lucee/lucee-docs/blob/master/",
				"one"
			);

			arrayAppend( output, {
				"title"   : results.title,
				"summary" : results.summary,
				"keywords": results.custom1,
				"source"  : src,
				"score"   : results.score,
				"rank"    : results.rank,
				"content" : passages
			});
		}

		return toTextContent( serializeJSON( output, false ) );
	}

	// -------------------------------------------------------------------------
	// Index management
	// -------------------------------------------------------------------------

	/**
	 * makes sure the index exists and was checked against its sources within the cache TTL
	 */
	private function ensureIndex() {
		var ttl   = getCacheTTL();
		var state = getIndexState();

		// fresh enough, nothing to do
		if ( ttl > 0 && state.indexed && now() < state.nextCheck ) return;

		// an index exists: check the sources in the background and use the existing index for this call
		if ( ttl > 0 && state.indexed ) {
			refreshInBackground();
			return;
		}

		// no index yet (or caching disabled): build it now
		lock name=static.LOCK_NAME type="exclusive" timeout=120 {
			state = getIndexState();
			if ( ttl > 0 && state.indexed && now() < state.nextCheck ) return;
			refreshIndex( ttl );
		}
	}

	private function refreshInBackground() {
		var state = getIndexState();
		if ( state.refreshing ) return;
		state.refreshing = true;
		try {
			thread name="mcp-search-index-#createUUID()#" action="run" {
				try {
					lock name=static.LOCK_NAME type="exclusive" timeout=1 throwOnTimeout=false {
						// another request may have refreshed the index in the meantime
						if ( now() >= getIndexState().nextCheck ) {
							refreshIndex( getCacheTTL() );
						}
					}
				}
				catch ( any e ) {
					log text="search_lucee_docs: background index refresh failed: #e.message#" type="error" log="application";
				}
				finally {
					getIndexState().refreshing = false;
				}
			}
		}
		catch ( any e ) {
			state.refreshing = false;
			rethrow;
		}
	}

	/**
	 * checks all sources and (re)indexes the ones that changed, must run inside the index lock
	 */
	private function refreshIndex( required numeric ttl ) {
		var complete = createIndex();
		var state    = getIndexState();
		state.indexed = true;
		state.lastCheck = now();
		// if a source could not be reached, check again sooner than the TTL
		var wait = complete ? arguments.ttl : min( arguments.ttl, static.RETRY_AFTER );
		state.nextCheck = dateAdd( "s", wait, state.lastCheck );
	}

	/**
	 * returns the shared index state (server scope, the collection is shared by the whole server)
	 */
	public struct function getIndexState() {
		if ( !structKeyExists( server, static.STATE_KEY ) ) {
			lock name="#static.LOCK_NAME#-state" type="exclusive" timeout=5 {
				if ( !structKeyExists( server, static.STATE_KEY ) ) {
					server[ static.STATE_KEY ] = {
						"indexed"   : false,
						"refreshing": false,
						"lastCheck" : "",
						"nextCheck" : now()
					};
				}
			}
		}
		return server[ static.STATE_KEY ];
	}

	/**
	 * cache TTL in seconds: system property "lucee.mcp.search.ttl", environment variable
	 * "LUCEE_MCP_SEARCH_TTL", default 3600. 0 disables the cache.
	 */
	public numeric function getCacheTTL() {
		var sys = createObject( "java", "java.lang.System" );
		var raw = sys.getProperty( "lucee.mcp.search.ttl" )
		       ?: sys.getenv( "LUCEE_MCP_SEARCH_TTL" )
		       ?: "";
		raw = trim( raw );
		if ( !len( raw ) || !isNumeric( raw ) || raw < 0 ) return static.DEFAULT_TTL;
		return int( raw );
	}

	/**
	 * indexes every source whose hash is not in the collection yet
	 * returns false if a source could not be loaded (what is already indexed for it is kept)
	 */
	private boolean function createIndex() {
		createCollection();

		cfindex( action="list", name="local.existing", collection=static.COLLECTION_NAME );
		var indexed = {};
		loop query=existing {
			indexed[ existing.custom4 ] = true;
		}

		var complete = true;
		// the hash of each source is checked before its data is loaded,
		// so unchanged sources are not rebuilt or downloaded again
		loop array=[ "function", "tag", "recipe" ] item="local.type" {
			var src = type == "function" ? getFunctionIndexData( indexed )
			        : type == "tag"      ? getTagIndexData( indexed )
			        :                      getRecipeIndexData( indexed );

			if ( !src.loaded ) {
				complete = false;
				continue;
			}
			if ( src.upToDate ) continue;

			cfindex(
				action     = "update"
				type       = "custom"
				collection = static.COLLECTION_NAME
				key        = "url"
				title      = "title"
				body       = src.bodyColumns
				custom1    = "keywords"
				custom2    = "url"
				custom4    = "hash:#src['hash']#"
				query      = src.name
			);
		}
		return complete;
	}

	private function createCollection() {
		cfcollection( action="list", name="local.cols" );
		loop query=cols {
			if ( cols.name == static.COLLECTION_NAME ) return;
		}
		try {
			var dir = expandPath( "{lucee-config-dir}/doc/search" );
			if ( !directoryExists( dir ) ) directoryCreate( dir, true );
		} catch( any e ) {
			var dir = expandPath( "{temp-directory}" );
		}
		cfcollection( action="create", collection=static.COLLECTION_NAME, path=dir );
	}

	private function searchSupported() {
		if ( !extensionExists( static.LUCENE_EXT_ID ) ) return false;
		var info = extensionInfo( static.LUCENE_EXT_ID );
		return listFirst( info.version, "." ) >= 3;
	}

	// -------------------------------------------------------------------------
	// Data loaders - return struct with keys: name, hash, bodyColumns, loaded, upToDate + query variable
	// the query is only built when the hash of the source is not indexed yet
	// -------------------------------------------------------------------------

	private function getFunctionIndexData( required struct indexed ) {
		var functions = getFunctionList();
		var result = {
			"name"       : "function",
			"hash"       : hash( structCount( functions ), "quick" ),
			"bodyColumns": "body",
			"loaded"     : true,
			"upToDate"   : false
		};
		if ( structKeyExists( indexed, "hash:#result.hash#" ) ) {
			result.upToDate = true;
			return result;
		}

		var qry = queryNew( [ "title", "body", "url", "keywords" ] );

		loop array=structKeyArray( functions ) item="local.fnName" {
			var data = getFunctionData( fnName );
			var row  = queryAddRow( qry );
			var body = trim( "
## Function #fnName#

Json function library descriptor for the function #fnName#

documentation: https://docs.lucee.org/reference/functions/#fnName#.html

```json
#serializeJSON( var:data, compact:false )#
```
			" );
			querySetCell( qry, "title",    fnName, row );
			querySetCell( qry, "body",     body,   row );
			querySetCell( qry, "url",      "https://docs.lucee.org/reference/functions/#lCase(fnName)#.html", row );
			querySetCell( qry, "keywords", "function,#lCase(fnName)#", row );
		}

		variables.function = qry;
		return result;
	}

	private function getTagIndexData( required struct indexed ) {
		var tagList = getTagList();
		var count   = 0;
		loop struct=tagList index="local.prefix" item="local.tags" {
			count += structCount( tags );
		}
		var result = {
			"name"       : "tag",
			"hash"       : hash( count, "quick" ),
			"bodyColumns": "body",
			"loaded"     : true,
			"upToDate"   : false
		};
		if ( structKeyExists( indexed, "hash:#result.hash#" ) ) {
			result.upToDate = true;
			return result;
		}

		var qry = queryNew( [ "title", "body", "url", "keywords" ] );

		loop struct=tagList index="local.prefix" item="local.tags" {
			loop array=structKeyArray( tags ) item="local.tagName" {
				var data = getTagData( prefix, tagName );
				var row  = queryAddRow( qry );
				var body = trim( "
## Tag #prefix##tagName#

Json tag library descriptor for the tag #prefix##tagName#

documentation: https://docs.lucee.org/reference/tags/#tagName#.html

```json
#serializeJSON( var:data, compact:false )#
```
				" );
				querySetCell( qry, "title",    "#prefix##tagName#", row );
				querySetCell( qry, "body",     body,                row );
				querySetCell( qry, "url",      "https://docs.lucee.org/reference/tags/#lCase(tagName)#.html", row );
				querySetCell( qry, "keywords", "tag,#lCase(tagName)#", row );
			}
		}

		variables.tag = qry;
		return result;
	}

	private function getRecipeIndexData( required struct indexed ) {
		var rootPath = server.system.environment.LUCEE_DOC_RECIPES_PATH
		             ?: "https://raw.githubusercontent.com/lucee/lucee-docs/master";

		var result = {
			"name"       : "recipe",
			"hash"       : "",
			"bodyColumns": "content,keywords",
			"loaded"     : false,
			"upToDate"   : false
		};

		// fetch remote index, if it can't be loaded the recipes already indexed are kept
		try {
			http url="#rootPath#/docs/recipes/index.json" timeout=10 result="local.res";
			if ( val( res.status_code ) < 200 || val( res.status_code ) >= 300 ) {
				log text="search_lucee_docs: recipe index not available (status #res.status_code#), keeping the recipes already indexed" type="warning" log="application";
				return result;
			}
			var index = deserializeJSON( res.filecontent );
		}
		catch ( any e ) {
			log text="search_lucee_docs: recipe index not available (#e.message#), keeping the recipes already indexed" type="warning" log="application";
			return result;
		}
		result.loaded = true;
		result.hash   = hash( res.filecontent, "md5" );
		if ( structKeyExists( indexed, "hash:#result.hash#" ) ) {
			result.upToDate = true;
			return result;
		}

		var qry   = queryNew( [ "title", "content", "url", "keywords" ] );

		loop array=index item="local.entry" {
			var recipeUrl = rootPath & entry.path;
			var content   = "";

			http url=recipeUrl timeout=10 result="local.recipeRes";
			if ( recipeRes.status_code >= 200 && recipeRes.status_code < 300 ) {
				// strip front matter comment block
				var raw      = recipeRes.filecontent;
				var endIndex = find( "-->", raw, 4 );
				content = endIndex > 0 ? trim( mid( raw, endIndex + 3 ) ) : trim( raw );
			}

			if ( !isEmpty( content ) ) {
				var row = queryAddRow( qry );
				var src = replace( recipeUrl,
					"https://raw.githubusercontent.com/lucee/lucee-docs/master/",
					"https://github.com/lucee/lucee-docs/blob/master/",
					"one"
				);
				var keywords = isArray( entry.keywords ?: "" )
				             ? arrayToList( entry.keywords )
				             : ( entry.keywords ?: "" );

				querySetCell( qry, "title",    entry.title ?: "",  row );
				querySetCell( qry, "content",  content,            row );
				querySetCell( qry, "url",      src,                row );
				querySetCell( qry, "keywords", keywords,           row );
			}
		}

		variables.recipe = qry;
		return result;
	}

}
