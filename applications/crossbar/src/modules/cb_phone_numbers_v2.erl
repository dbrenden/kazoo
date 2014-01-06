-module(cb_phone_numbers_v2).

-export([authenticate/1]).
-export([authorize/1]).
-export([allowed_methods/1]).
-export([resource_exists/1]).
-export([validate/1, validate/2, validate/3, validate/4]).
-export([put/2, put/3, put/4]).
-export([post/2]).

-include("../crossbar.hrl").
-include_lib("whistle_number_manager/include/wh_number_manager.hrl").

-define(PORT_DOCS, <<"docs">>).
-define(PORT, <<"port">>).
-define(ACTIVATE, <<"activate">>).
-define(RESERVE, <<"reserve">>).
-define(CLASSIFIERS, <<"classifiers">>).
-define(IDENTIFY, <<"identify">>).
-define(COLLECTION, <<"collection">>).

-define(FIND_NUMBER_SCHEMA, "{\"$schema\": \"http://json-schema.org/draft-03/schema#\", \"id\": \"http://json-schema.org/draft-03/schema#\", \"properties\": {\"prefix\": {\"required\": \"true\", \"type\": \"string\", \"minLength\": 3, \"maxLength\": 10}, \"quantity\": {\"default\": 1, \"type\": \"integer\", \"minimum\": 1}}}").
-define(DEFAULT_COUNTRY, <<"US">>).
-define(PHONE_NUMBERS_CONFIG_CAT, <<"crossbar.phone_numbers">>).
-define(FREE_URL, <<"phonebook_url">>).
-define(PAYED_URL, <<"phonebook_url_premium">>).
-define(PREFIX, <<"prefix">>).
-define(LOCALITY, <<"locality">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Authenticates the incoming request, returning true if the requestor is
%% known, or false if not.
%% @end
%%--------------------------------------------------------------------
-spec authenticate(cb_context:context()) -> 'true'.
authenticate(#cb_context{req_nouns=[{<<"phone_numbers">>,[?PREFIX]}]
                         ,req_verb = ?HTTP_GET
                        }) ->
    'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Authorizes the incoming request, returning true if the requestor is
%% allowed to access the resource, or false if not.
%% @end
%%--------------------------------------------------------------------
-spec authorize(cb_context:context()) -> 'true'.
authorize(#cb_context{req_nouns=[{<<"phone_numbers">>,[?PREFIX]}]
                      ,req_verb = ?HTTP_GET
                     }) ->
    'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods(path_token()) -> http_methods().
allowed_methods(?PREFIX) -> [?HTTP_GET];
allowed_methods(?LOCALITY) -> [?HTTP_POST].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists(path_token()) -> 'true'.
resource_exists(?PREFIX) -> 'true';
resource_exists(?LOCALITY) -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().

validate(#cb_context{req_verb = ?HTTP_GET
                     ,account_id='undefined'
                    }=Context) ->
    find_numbers(Context);
validate(#cb_context{req_verb = ?HTTP_GET}=Context) ->
    summary(Context).

validate(#cb_context{req_verb = ?HTTP_GET}=Context, ?PREFIX) ->
    find_prefix(Context);
validate(#cb_context{req_verb = ?HTTP_GET}=Context, Number) ->
    cb_phone_numbers:read(Number, Context);
validate(#cb_context{req_verb = ?HTTP_POST}=Context, ?LOCALITY) ->
    find_locality(Context);
validate(#cb_context{req_verb = ?HTTP_POST}=Context, _Number) ->
    cb_phone_numbers:validate_request(Context).

validate(Context, PathToken, PathToken1) ->
    cb_phone_numbers:validate(Context, PathToken, PathToken1).

validate(Context, PathToken, PathToken1, PathToken2) ->
    cb_phone_numbers:validate(Context, PathToken, PathToken1, PathToken2).

-spec put(cb_context:context(), path_token()) ->
                 cb_context:context().
-spec put(cb_context:context(), path_token(), path_token()) ->
                 cb_context:context().
-spec put(cb_context:context(), path_token(), path_token(), path_token()) ->
                 cb_context:context().
put(Context, ?COLLECTION) ->
    Results = collection_process(Context),
    set_response(Results, <<>>, Context);
put(#cb_context{req_json=ReqJObj}=Context, Number) ->
    Result = wh_number_manager:create_number(Number
                                             ,cb_context:account_id(Context)
                                             ,cb_context:auth_account_id(Context)
                                             ,cb_context:doc(Context)
                                             ,(not wh_json:is_true(<<"accept_charges">>, ReqJObj))
                                            ),
    set_response(Result, Number, Context).

put(Context, ?COLLECTION, ?ACTIVATE) ->
    Results = collection_process(Context, ?ACTIVATE),
    set_response(Results, <<>>, Context);
put(#cb_context{req_json=ReqJObj}=Context, Number, ?PORT) ->
    Result = wh_number_manager:port_in(Number
                                       ,cb_context:account_id(Context)
                                       ,cb_context:auth_account_id(Context)
                                       ,cb_context:doc(Context)
                                       ,(not wh_json:is_true(<<"accept_charges">>, ReqJObj))
                                      ),
    set_response(Result, Number, Context);
put(#cb_context{req_json=ReqJObj}=Context, Number, ?ACTIVATE) ->
    Result = wh_number_manager:assign_number_to_account(Number
                                                        ,cb_context:account_id(Context)
                                                        ,cb_context:auth_account_id(Context)
                                                        ,cb_context:doc(Context)
                                                        ,(not wh_json:is_true(<<"accept_charges">>, ReqJObj))
                                                       ),
    set_response(Result, Number, Context);
put(#cb_context{req_json=ReqJObj}=Context, Number, ?RESERVE) ->
    Result = wh_number_manager:reserve_number(Number
                                              ,cb_context:account_id(Context)
                                              ,cb_context:auth_account_id(Context)
                                              ,cb_context:doc(Context)
                                              ,(not wh_json:is_true(<<"accept_charges">>, ReqJObj))
                                             ),
    set_response(Result, Number, Context);
put(Context, Number, ?PORT_DOCS) ->
    cb_phone_numbers:put(Context, Number, ?PORT_DOCS).

put(Context, Number, ?PORT_DOCS, T) ->
    cb_phone_numbers:put(Context, Number, ?PORT_DOCS, T).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec post(cb_context:context(), path_token()) -> cb_context:context().
post(Context, ?LOCALITY) -> Context;
post(Context, ?COLLECTION) ->
    Result = collection_process(Context),
    set_response(Result, <<>>, Context);
post(#cb_context{req_json=ReqJObj}=Context, Number) ->
    Result = wh_number_manager:set_public_fields(Number
                                                 ,cb_context:doc(Context)
                                                 ,cb_context:auth_account_id(Context)
                                                 ,(not wh_json:is_true(<<"accept_charges">>, ReqJObj))
                                                ),
    set_response(Result, Number, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec summary(cb_context:context()) -> cb_context:context().
summary(Context) ->
    case cb_phone_numbers:summary(Context) of
        #cb_context{resp_status='success'}=C ->
            maybe_update_locality(C);
        Else -> Else
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec find_numbers(cb_context:context()) -> cb_context:context().
find_numbers(Context) ->
    AccountId = cb_context:auth_account_id(Context),
    JObj = wh_json:set_value(<<"Account-ID">>, AccountId, cb_context:query_string(Context)),
    Prefix = wh_json:get_ne_value(<<"prefix">>, JObj),
    Quantity = wh_json:get_ne_value(<<"quantity">>, JObj, 1),
    OnSuccess = fun(C) ->
                    cb_context:set_resp_data(
                      cb_context:set_resp_status(C, 'success')
                      ,wh_number_manager:find(Prefix, Quantity, wh_json:to_proplist(JObj))
                     )
                end,
    Schema = wh_json:decode(?FIND_NUMBER_SCHEMA),
    cb_context:validate_request_data(Schema
                                     ,cb_context:set_req_data(Context, JObj)
                                     ,OnSuccess
                                    ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec find_prefix(cb_context:context()) -> cb_context:context().
find_prefix(Context) ->
    QS = cb_context:query_string(Context),
    case wh_json:get_ne_value(<<"city">>, QS) of
        'undefined' -> cb_context:add_system_error('bad_identifier', Context);
        City ->
            case get_prefix(City) of
                {'ok', Data} ->
                    cb_context:set_resp_data(
                        cb_context:set_resp_status(Context, 'success')
                        ,Data
                    );
                {'error', Error} ->
                    lager:error("error while prefix for city: ~p : ~p", [City, Error]),
                    cb_context:set_resp_data(
                        cb_context:set_resp_status(Context, 'error')
                        ,Error
                    )
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% resource.
%% @end
%%--------------------------------------------------------------------
-spec find_locality(cb_context:context()) -> cb_context:context().
find_locality(#cb_context{req_data=Data}=Context) ->
    case wh_json:get_value(<<"numbers">>, Data) of
        'undefined' ->
            cb_context:add_validation_error(<<"numbers">>
                                            ,<<"required">>
                                            ,<<"list of numbers missing">>
                                            ,Context
                                           );
        [] ->
           cb_context:add_validation_error(<<"numbers">>
                                            ,<<"minimum">>
                                            ,<<"minimum 1 number required">>
                                            ,Context
                                          );
        Numbers when is_list(Numbers) ->
            Url = get_url(wh_json:get_value(<<"quality">>, Data)),
            case get_locality(Numbers, Url) of
                {'error', E} ->
                    crossbar_util:response('error', E, 500, Context);
                {'ok', Localities} ->
                    cb_context:set_resp_data(
                      cb_context:set_resp_status(Context, 'success')
                      ,Localities
                     )
            end;
        _E ->
            cb_context:add_validation_error(<<"numbers">>
                                            ,<<"type">>
                                            ,<<"numbers must be a list">>
                                            ,Context
                                           )
    end.

-spec get_url(any()) -> binary().
get_url(<<"high">>) -> ?PAYED_URL;
get_url(_) -> ?FREE_URL.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% resource.
%% @end
%%--------------------------------------------------------------------
-spec get_prefix(ne_binary()) ->
                        {'ok', wh_json:object()} |
                        {'error', any()}.
get_prefix(City) ->
    Country = whapps_config:get(?PHONE_NUMBERS_CONFIG_CAT, <<"default_country">>, ?DEFAULT_COUNTRY),
    case whapps_config:get(?PHONE_NUMBERS_CONFIG_CAT, ?FREE_URL) of
        'undefined' ->
            {'error', <<"Unable to acquire numbers missing carrier url">>};
        Url ->
            ReqParam  = wh_util:uri_encode(binary:bin_to_list(City)),
            Req = binary:bin_to_list(<<Url/binary, "/", Country/binary, "/city?pattern=">>),
            Uri = lists:append(Req, ReqParam),
            case ibrowse:send_req(Uri, [], 'get') of
                {'error', Reason} ->
                    {'error', Reason};
                {'ok', "200", _Headers, Body} ->
                    JObj =  wh_json:decode(Body),
                    case wh_json:get_value(<<"data">>, JObj) of
                        'undefined' -> {'error ', JObj};
                        Data -> {'ok', Data}
                    end;
                {'ok', _Status, _Headers, Body} ->
                    {'error', wh_json:decode(Body)}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% resource.
%% @end
%%--------------------------------------------------------------------
-spec maybe_update_locality(cb_context:context()) ->
                                   cb_context:context().
maybe_update_locality(Context) ->
    Numbers = wh_json:foldl(
                fun(Key, Value, Acc) ->
                        case wh_json:get_value(<<"locality">>, Value) =:= 'undefined'
                            andalso  wnm_util:is_reconcilable(Key)
                        of
                            'true' -> [Key|Acc];
                            'false' -> Acc
                        end
                end
                ,[]
                ,wh_json:get_value(<<"numbers">>, cb_context:resp_data(Context))
               ),
    update_locality(Context, Numbers).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_locality(cb_context:context(), ne_binaries()) ->
                             cb_context:context().
update_locality(Context, []) -> Context;
update_locality(Context, Numbers) ->
    case get_locality(Numbers, ?FREE_URL) of
        {'error', _} -> Context;
        {'ok', Localities} ->
            _ = spawn(fun() ->
                              update_phone_numbers_locality(Context, Localities)
                      end),
            update_context_locality(Context, Localities)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_context_locality(cb_context:context(), wh_json:object()) ->
                                     cb_context:context().
update_context_locality(Context, Localities) ->
    JObj = wh_json:foldl(fun(Key, Value, J) ->
                                 wh_json:set_value([<<"numbers">>
                                                    ,Key
                                                    ,<<"locality">>
                                                   ], Value, J)
                         end, cb_context:resp_data(Context), Localities),
    cb_context:set_resp_data(Context, JObj).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_phone_numbers_locality(cb_context:context(), wh_json:object()) ->
                                           {'ok', wh_json:object()} |
                                           {'error', _}.
update_phone_numbers_locality(Context, Localities) ->
    AccountDb = cb_context:account_db(Context),
    DocId = wh_json:get_value(<<"_id">>, cb_context:doc(Context), <<"phone_numbers">>),
    case couch_mgr:open_doc(AccountDb, DocId) of
        {'ok', JObj} ->
            J = wh_json:foldl(fun(Key, Value, J) ->
                                      case wh_json:get_value(Key, J) of
                                          'undefined' -> J;
                                          _Else ->
                                              wh_json:set_value([Key
                                                                 ,<<"locality">>
                                                                ], Value, J)
                                      end
                              end, JObj, Localities),
            couch_mgr:save_doc(AccountDb, J);
        {'error', _E}=E ->
            lager:error("failed to update locality for ~s in ~s: ~p", [DocId, AccountDb, _E]),
            E
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% resource.
%% @end
%%--------------------------------------------------------------------
-spec get_locality(ne_binaries(), ne_binary()) ->
                          {'error', ne_binary()} |
                          {'ok', wh_json:object()}.
get_locality([], _) -> {'error', <<"number missing">>};
get_locality(Numbers, UrlType) ->
    case whapps_config:get(?PHONE_NUMBERS_CONFIG_CAT, UrlType) of
        'undefined' ->
            lager:error("could not get number locality url"),
            {'error', <<"missing phonebook url">>};
        Url ->
            ReqBody = wh_json:set_value(<<"data">>, Numbers, wh_json:new()),
            Uri = <<Url/binary, "/location">>,
            case ibrowse:send_req(binary:bin_to_list(Uri), [], 'post', wh_json:encode(ReqBody)) of
                {'error', Reason} ->
                    lager:error("number locality lookup failed: ~p", [Reason]),
                    {'error', <<"number locality lookup failed">>};
                {'ok', "200", _Headers, Body} ->
                    handle_locality_resp(wh_json:decode(Body));
                {'ok', _Status, _, _Body} ->
                    lager:error("number locality lookup failed: ~p ~p", [_Status, _Body]),
                    {'error', <<"number locality lookup failed">>}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_locality_resp(wh_json:object()) ->
                                  {'error', ne_binary()} |
                                  {'ok', wh_json:object()}.
handle_locality_resp(Resp) ->
    case wh_json:get_value(<<"status">>, Resp, <<"error">>) of
        <<"success">> ->
            {'ok', wh_json:get_value(<<"data">>, Resp, wh_json:new())};
        _E ->
            lager:error("number locality lookup failed, status: ~p", [_E]),
            {'error', <<"number locality lookup failed">>}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec set_response({'ok', operation_return()} |
                   operation_return() |
                   {binary(), binary()}, binary()
                   ,cb_context:context()) ->
                          cb_context:context().
set_response({'dry_run', Doc}, _, Context) ->
    io:format("cb_phone_numbers_v2.erl:MARKER:478 ~p~n", [Doc]),
    crossbar_util:response_402(Doc, Context);
set_response({'dry_run', ?COLLECTION, Doc}, _, Context) ->
    io:format("cb_phone_numbers_v2.erl:MARKER:481 ~p~n", [Doc]),
    crossbar_util:response_402(Doc, Context);
set_response(Else, Num, Context) ->
    cb_phone_numbers:set_response(Else, Num, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec collection_process(cb_context:context()) ->
                                operation_return() |
                                {'ok', operation_return()}.
-spec collection_process(cb_context:context(), ne_binary() | ne_binaries()) ->
                                operation_return() |
                                {'ok', operation_return()}.
collection_process(#cb_context{req_data=ReqJObj}=Context) ->
    Numbers = wh_json:get_value(<<"numbers">>, cb_context:req_data(Context), []),
    Result = collection_process(Context, Numbers, 'undefined'),
    case (not wh_json:is_true(<<"accept_charges">>, ReqJObj, 'false')) of
        'true' -> {'dry_run', ?COLLECTION, Result};
        'false' -> {'ok', Result}
    end.

collection_process(#cb_context{req_data=ReqJObj}=Context, ?ACTIVATE) ->
    Numbers = wh_json:get_value(<<"numbers">>, cb_context:req_data(Context), []),
    Result = collection_process(Context, Numbers, ?ACTIVATE),
    case (not wh_json:is_true(<<"accept_charges">>, ReqJObj, 'false')) of
        'true' -> {'dry_run', ?COLLECTION, Result};
        'false' -> {'ok', Result}
    end.

collection_process(Context, Numbers, Action) ->
    lists:foldl(
        fun(Number, Acc) ->
            case collection_action(Context, Number, Action) of
                {'ok', JObj} ->
                    wh_json:set_value([<<"success">>, Number], JObj, Acc);
                {'dry_run', Data} ->
                    wh_json:set_value([<<"charges">>, Number], Data, Acc);
                {State, _} ->
                    JObj = wh_json:set_value(<<"reason">>, State, wh_json:new()),
                    wh_json:set_value([<<"error">>, Number], JObj, Acc)
            end
        end
        ,wh_json:new()
        ,Numbers
     ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec collection_action(cb_context:context(), ne_binary(), ne_binary()) ->
                               operation_return().
collection_action(#cb_context{account_id=AssignTo
                              ,auth_account_id=AuthBy
                              ,doc=JObj
                              ,req_verb = ?HTTP_PUT
                              ,req_data=ReqJObj
                             }, Number, ?ACTIVATE) ->
    DryRun = (not wh_json:is_true(<<"accept_charges">>, ReqJObj, 'false')),
    case wh_number_manager:assign_number_to_account(Number, AssignTo, AuthBy, JObj, DryRun) of
        {'ok', RJObj} ->
            {'ok', wh_json:delete_key(<<"numbers">>, RJObj)};
        {'dry_run', _Data}=Resp ->Resp;
        Else -> Else
    end;
collection_action(#cb_context{account_id=AssignTo
                              ,auth_account_id=AuthBy
                              ,doc=JObj
                              ,req_verb = ?HTTP_PUT
                             }, Number, _) ->
    wh_number_manager:create_number(Number, AssignTo, AuthBy, wh_json:delete_key(<<"numbers">>, JObj));
collection_action(#cb_context{auth_account_id=AuthBy
                              ,doc=Doc
                              ,req_data=ReqJObj
                              ,req_verb = ?HTTP_POST
                             }, Number, _) ->
    case wh_number_manager:get_public_fields(Number, AuthBy) of
        {'ok', JObj} ->
            Doc1 = wh_json:delete_key(<<"numbers">>, Doc),
            DryRun = (not wh_json:is_true(<<"accept_charges">>, ReqJObj, 'false')),
            wh_number_manager:set_public_fields(Number, wh_json:merge_jobjs(JObj, Doc1), AuthBy, DryRun);
        {State, Error} ->
            lager:error("error while fetching number ~p : ~p", [Number, Error]),
            {State, Error}
    end;
collection_action(#cb_context{auth_account_id=AuthBy
                              ,req_verb = ?HTTP_DELETE
                             }, Number, _) ->
    wh_number_manager:release_number(Number, AuthBy).

