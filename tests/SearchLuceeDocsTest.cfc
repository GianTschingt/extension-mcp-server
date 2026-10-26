<!--- 
*
* Copyright (c) 2026, Lucee Association Switzerland. All rights reserved.
*
* This library is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either 
* version 2.1 of the License, or (at your option) any later version.
* 
* This library is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* Lesser General Public License for more details.
* 
* You should have received a copy of the GNU Lesser General Public 
* License along with this library.  If not, see <http://www.gnu.org/licenses/>.
* 
---><cfscript>
component extends="org.lucee.cfml.test.LuceeTestCase" labels="mcpserver" {

    function beforeAll() {
        variables.tool = new org.lucee.extension.mcp.tools.SearchLuceeDocs();
        variables.system = createObject( "java", "java.lang.System" );
        variables.ttlProp = "lucee.mcp.search.ttl";
        variables.ttlOrg = system.getProperty( ttlProp );
        variables.searchSupported = extensionExists( "EFDEB172-F52E-4D84-9CD1A1F561B3DFC8" )
            && listFirst( extensionInfo( "EFDEB172-F52E-4D84-9CD1A1F561B3DFC8" ).version, "." ) >= 3;
    }

    function afterAll() {
        restoreTTL();
    }

    // waits until a background refresh started by an earlier call is finished
    private function waitForBackgroundRefresh() {
        var started = getTickCount();
        while ( tool.getIndexState().refreshing ) {
            if ( getTickCount() - started > 120000 ) throw( message: "background index refresh did not finish within 120 seconds" );
            sleep( 100 );
        }
    }

    private function restoreTTL() {
        if ( isNull( ttlOrg ) ) system.clearProperty( ttlProp );
        else system.setProperty( ttlProp, ttlOrg );
    }

    function run( testResults, testBox ) {

        describe( "checking the SearchLuceeDocs tool", function() {

            it( "checking name", function() {
                expect( tool.getName() ).toBe( "search_lucee_docs" );
            });

            it( "checking description", function() {
                expect( len( tool.getDescription() ) > 0 ).toBeTrue();
            });

            it( "checking inputSchema", function() {
                var schema = tool.getInputSchema();

                // required
                expect( isArray( schema.required ) ).toBeTrue();
                expect( arrayLen( schema.required ) ).toBe( 1 );
                expect( schema.required[1] ).toBe( "query" );

                // type
                expect( schema.type ).toBe( "object" );

                // properties
                expect( isStruct( schema.properties ) ).toBeTrue();
                expect( structKeyExists( schema.properties, "query" ) ).toBeTrue();
                expect( isStruct( schema.properties.query ) ).toBeTrue();
                expect( structKeyExists( schema.properties.query, "type" ) ).toBeTrue();
                expect( schema.properties.query.type ).toBe( "string" );
                expect( len( schema.properties.query.description ) > 0 ).toBeTrue();

                // optional maxResults property
                expect( structKeyExists( schema.properties, "maxResults" ) ).toBeTrue();
                expect( schema.properties.maxResults.type ).toBe( "integer" );
            });

            it( "checking exec returns correct content structure", function() {
                var result = tool.exec( { query: "arraySort" } );

                expect( isStruct( result ) ).toBeTrue();
                expect( structKeyExists( result, "content" ) ).toBeTrue();
                expect( isArray( result.content ) ).toBeTrue();
                expect( isStruct( result.content[1] ) ).toBeTrue();
                expect( structKeyExists( result.content[1], "type" ) ).toBeTrue();
                expect( result.content[1].type ).toBe( "text" );
                expect( len( result.content[1].text ) > 0 ).toBeTrue();
            });

            // disabled: Lucee 8 uninstalls the Lucene extension installed via LUCEE_EXTENSIONS on startup, so search is unavailable in CI
            xit( "search returns results for known term", function() {
                var result = tool.exec( { query: "arraySort" } );

                expect( findNoCase( "arraySort", result.content[1].text ) > 0 ).toBeTrue();
            });

            it( "maxResults limits number of results", function() {
                var result1 = tool.exec( { query: "array", maxResults: 1 } );
                var result3 = tool.exec( { query: "array", maxResults: 3 } );

                // both return content — we can't assert exact counts from the text
                // but we can assert the larger request returns more or equal text
                expect( len( result3.content[1].text ) >= len( result1.content[1].text ) ).toBeTrue();
            });

            it( "cache TTL is configurable with a system property", function() {
                try {
                    system.setProperty( ttlProp, "120" );
                    expect( tool.getCacheTTL() ).toBe( 120 );
                    system.setProperty( ttlProp, "0" );
                    expect( tool.getCacheTTL() ).toBe( 0 );
                    // invalid values fall back to the default
                    system.setProperty( ttlProp, "abc" );
                    expect( tool.getCacheTTL() ).toBe( 3600 );
                    system.setProperty( ttlProp, "-5" );
                    expect( tool.getCacheTTL() ).toBe( 3600 );
                }
                finally {
                    restoreTTL();
                }
            });

            it( "cache TTL defaults to 3600 seconds", function() {
                if ( len( system.getenv( "LUCEE_MCP_SEARCH_TTL" ) ?: "" ) ) return;
                try {
                    system.clearProperty( ttlProp );
                    expect( tool.getCacheTTL() ).toBe( 3600 );
                }
                finally {
                    restoreTTL();
                }
            });

            it( "index is not checked again within the cache TTL", function() {
                if ( !searchSupported ) return;
                try {
                    system.setProperty( ttlProp, "3600" );
                    tool.exec( { query: "arraySort" } );
                    waitForBackgroundRefresh();
                    var state = tool.getIndexState();
                    expect( state.indexed ).toBeTrue();
                    expect( state.nextCheck ).toBeGT( now() );
                    var lastCheck = state.lastCheck;

                    sleep( 1100 );
                    tool.exec( { query: "arrayEach" } );
                    expect( tool.getIndexState().lastCheck ).toBe( lastCheck );
                }
                finally {
                    restoreTTL();
                }
            });

            it( "index is checked on every call with TTL 0", function() {
                if ( !searchSupported ) return;
                try {
                    system.setProperty( ttlProp, "0" );
                    waitForBackgroundRefresh();
                    tool.exec( { query: "arraySort" } );
                    var lastCheck = tool.getIndexState().lastCheck;

                    sleep( 1100 );
                    tool.exec( { query: "arrayEach" } );
                    expect( tool.getIndexState().lastCheck ).toBeGT( lastCheck );
                }
                finally {
                    restoreTTL();
                }
            });

            it( "expired index is refreshed in the background", function() {
                if ( !searchSupported ) return;
                try {
                    system.setProperty( ttlProp, "1" );
                    waitForBackgroundRefresh();
                    tool.exec( { query: "arraySort" } );
                    waitForBackgroundRefresh();
                    var lastCheck = tool.getIndexState().lastCheck;

                    sleep( 1100 );
                    // served from the existing index while the refresh runs in the background
                    var result = tool.exec( { query: "arraySort" } );
                    expect( findNoCase( "arraySort", result.content[1].text ) > 0 ).toBeTrue();
                    waitForBackgroundRefresh();
                    expect( tool.getIndexState().lastCheck ).toBeGT( lastCheck );
                }
                finally {
                    restoreTTL();
                }
            });

            it( "no results returns graceful not-found content", function() {
                var result = tool.exec( { query: "zzznoresultsxxx99999" } );

                expect( isStruct( result ) ).toBeTrue();
                expect( structKeyExists( result, "content" ) ).toBeTrue();
                expect( result.content[1].type ).toBe( "text" );
                expect( len( result.content[1].text ) > 0 ).toBeTrue();
            });

        });
    }
}
</cfscript>
