%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, 2600Hz
%%% @doc
%%% Account document
%%% @end
%%% @contributors
%%% 
%%%-------------------------------------------------------------------
-module(stepswitch_resources_test).

-include_lib("eunit/include/eunit.hrl").
-include("src/stepswitch.hrl").

-define(RESOURCE_1_ID, <<"resource000000000000000000000001">>).

check_fixtures_test_() ->
    {'ok', Schema} = kz_json_schema:fload(<<"resources">>),
    {'ok', Resources} = kz_json:fixture(?APP, <<"fixtures/resources/global.json">>),
    [{"validate resource fixture", ?_assertMatch({'ok', _}, validate(Schema, Resource))}
    || Resource <- Resources
    ].

invite_parameters_test2_() ->
    {'ok', Offnet} = kz_json:fixture(?APP, <<"fixtures/offnet_req/global.json">>),
   % {'ok', [ResourceJObj|_]} = kz_json:fixture(?APP, <<"fixtures/resources/global.json">>),
   % [GatewayJObj|_] = kz_json:get_value(<<"gateways">>, ResourceJObj),
   % Resource = stepswitch_resources:resource_from_jobj(ResourceJObj),
   % Gateway = stepswitch_resources:gateway_from_jobj(GatewayJObj, Resource),
    % example L = [<<"npid">>, <<"location=test@2600hz.com">>, <<"account_id=Me">>, <<"0288">>]

   % GatewayJObj1 = kz_json:set_value([<<"invite_parameters">>, <<"static">>], [<<"test">>], GatewayJObj),
   % Gateway1 = stepswitch_resources:gateway_from_jobj(GatewayJObj1, Resource),

   % Offnet1 = kz_json:set_value([<<"Requestor-Custom-Channel-Vars">>, <<"TNS-CIC">>], <<"cic=2002">>, Offnet),
   % Offnet2 = kz_json:set_value([<<"Requestor-Custom-Channel-Vars">>, <<"Account-ID">>], <<"12345">>, Offnet),
   % Offnet3 = kz_json:set_value([<<"Requestor-Custom-SIP-Headers">>, <<"X-Auth-IP">>], <<"127.0.0.1">>, Offnet),

    %DynamicParameters1 = kz_json:from_list([{<<"key">>, <<"custom_sip_headers.x_auth_ip">>}, {<<"tag">>, <<"somethingelse">>}]),
    %GatewayJObj2 = kz_json:set_value([<<"invite_parameters">>, <<"dynamic">>], [DynamicParameters1], GatewayJObj),
    %Gateway2 = stepswitch_resources:gateway_from_jobj(GatewayJObj2, Resource),

    %DynamicParameters2 = kz_json:from_list([{<<"key">>, <<"custom_sip_headers.x_auth_ip">>}, {<<"tag">>, <<"somethingelse">>}, {<<"seperator">>, <<"&">>}]),

    Setup = [{<<"cic=2002">>
             ,[<<"Requestor-Custom-Channel-Vars", <<"TNS-CIC">>]
             ,fun kz_json:get_value/2
             ,fun kz_json:set_value/2)
             }
            ]
    [?_assertEqual(Expected, Getter(Expected, Object)) || {Expected, Object, Getter, Setter} <- Setup]


validate(Schema, Object) ->
    kz_json_schema:validate(Schema
                           ,Object
                           ,[{'schema_loader_fun', fun kz_json_schema:fload/1}]
                           ).
