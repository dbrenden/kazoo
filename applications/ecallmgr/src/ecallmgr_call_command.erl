%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2017, 2600Hz INC
%%% @doc
%%% Execute call commands
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Karl Anderson
%%%
%%%-------------------------------------------------------------------
-module(ecallmgr_call_command).

-export([exec_cmd/4]).
-export([fetch_dialplan/4]).

-ifdef(TEST).
-export([get_conference_flags/1
        ,tones_app/1
        ]).
-endif.

-include("ecallmgr.hrl").

-define(RECORD_SOFTWARE, ecallmgr_config:get_ne_binary(<<"recording_software_name">>, <<"2600Hz, Inc.'s Kazoo">>)).

-spec exec_cmd(atom(), ne_binary(), kz_json:object(), api_pid()) ->
                      'ok' |
                      'error' |
                      ecallmgr_util:send_cmd_ret() |
                      [ecallmgr_util:send_cmd_ret(),...].
exec_cmd(Node, UUID, JObj, ControlPID) ->
    exec_cmd(Node, UUID, JObj, ControlPID, kz_json:get_value(<<"Call-ID">>, JObj)).

exec_cmd(Node, UUID, JObj, ControlPid, UUID) ->
    App = kz_json:get_value(<<"Application-Name">>, JObj),
    case get_fs_app(Node, UUID, JObj, App) of
        {'error', Msg} -> throw({'msg', Msg});
        {'return', Result} -> Result;
        {AppName, 'noop'} ->
            ecallmgr_call_control:event_execute_complete(ControlPid, UUID, AppName);
        {AppName, AppData} ->
            ecallmgr_util:send_cmd(Node, UUID, AppName, AppData);
        {AppName, AppData, NewNode} ->
            ecallmgr_util:send_cmd(NewNode, UUID, AppName, AppData);
        [_|_]=Apps ->
            [ecallmgr_util:send_cmd(Node, UUID, AppName, AppData) || {AppName, AppData} <- Apps]
    end;
exec_cmd(_Node, _UUID, JObj, _ControlPid, _DestId) ->
    lager:debug("command ~s not meant for us but for ~s", [kz_json:get_value(<<"Application-Name">>, JObj), _DestId]),
    throw(<<"call command provided with a command for a different call id">>).

-spec fetch_dialplan(atom(), ne_binary(), kz_json:object(), api_pid()) -> fs_apps().
fetch_dialplan(Node, UUID, JObj, _ControlPid) ->
    App = kz_json:get_value(<<"Application-Name">>, JObj),
    case get_fs_app(Node, UUID, JObj, App) of
        {'error', Msg} -> throw({'msg', Msg});
        {'return', _Result} -> [];
        {_AppName, _AppData, _NewNode} -> [];
        {AppName, AppData} -> [{AppName, AppData}];
        [_|_]=Apps -> Apps
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% return the app name and data (as a binary string) to send to
%% the FS ESL via mod_erlang_event
%% @end
%%--------------------------------------------------------------------
-spec get_fs_app(atom(), ne_binary(), kz_json:object(), ne_binary()) ->
                        fs_app() | fs_apps() |
                        {'return', 'error' | ne_binary()} |
                        {'error', ne_binary()}.
get_fs_app(Node, UUID, JObj, <<"noop">>) ->
    case kapi_dialplan:noop_v(JObj) of
        'false' ->
            {'error', <<"noop failed to execute as JObj did not validate">>};
        'true' ->
            _ = ecallmgr_fs_bridge:maybe_b_leg_events(Node, UUID, JObj),
            Args = case kz_json:get_value(<<"Msg-ID">>, JObj) of
                       'undefined' ->
                           <<"Event-Subclass=kazoo::noop,Event-Name=CUSTOM"
                             ,",kazoo_event_name=CHANNEL_EXECUTE_COMPLETE"
                             ,",kazoo_application_name=noop"
                           >>;
                       NoopId ->
                           <<"Event-Subclass=kazoo::noop,Event-Name=CUSTOM"
                             ,",kazoo_event_name=CHANNEL_EXECUTE_COMPLETE"
                             ,",kazoo_application_name=noop"
                             ,",kazoo_application_response=", (kz_term:to_binary(NoopId))/binary
                           >>
                   end,
            {<<"event">>, Args}
    end;

get_fs_app(Node, UUID, JObj, <<"tts">>) ->
    case kapi_dialplan:tts_v(JObj) of
        'false' -> {'error', <<"tts failed to execute as JObj didn't validate">>};
        'true' ->
            tts(Node, UUID, JObj)
    end;

get_fs_app(Node, UUID, JObj, <<"play">>) ->
    case kapi_dialplan:play_v(JObj) of
        'false' -> {'error', <<"play failed to execute as JObj did not validate">>};
        'true' -> play(Node, UUID, JObj)
    end;

get_fs_app(_Node, _UUID, JObj, <<"break">>) ->
    case kapi_dialplan:break_v(JObj) of
        'false' -> {'error', <<"break failed to execute as JObj did not validate">>};
        'true' -> {<<"break">>, <<>>}
    end;

get_fs_app(_Node, _UUID, JObj, <<"playstop">>) ->
    case kapi_dialplan:playstop_v(JObj) of
        'false' -> {'error', <<"playstop failed to execute as JObj did not validate">>};
        'true' -> {<<"playstop">>, <<>>}
    end;

get_fs_app(_Node, _UUID, JObj, <<"hangup">>) ->
    case kz_json:is_true(<<"Other-Leg-Only">>, JObj, 'false') of
        'false' -> {<<"hangup">>, <<>>};
        'true' ->  {<<"unbridge">>, <<>>}
    end;

get_fs_app(_Node, UUID, JObj, <<"audio_level">>) ->
    Action = kz_json:get_ne_binary_value(<<"Action">>, JObj),
    Level = kz_json:get_ne_binary_value(<<"Level">>, JObj),
    Mode = kz_json:get_ne_binary_value(<<"Mode">>, JObj),
    Data = <<UUID/binary, " ", Action/binary, " ", Mode/binary, " mute ", Level/binary>>,
    {<<"audio_level">>, Data};

get_fs_app(_Node, UUID, JObj, <<"play_and_collect_digits">>) ->
    case kapi_dialplan:play_and_collect_digits_v(JObj) of
        'false' -> {'error', <<"play_and_collect_digits failed to execute as JObj did not validate">>};
        'true' ->
            Min = kz_json:get_value(<<"Minimum-Digits">>, JObj),
            Max = kz_json:get_value(<<"Maximum-Digits">>, JObj),
            Timeout = kz_json:get_value(<<"Timeout">>, JObj),
            Terminators = kz_json:get_value(<<"Terminators">>, JObj),
            Media = <<$', (ecallmgr_util:media_path(kz_json:get_value(<<"Media-Name">>, JObj), 'new', UUID, JObj))/binary, $'>>,
            InvalidMedia = <<$', (ecallmgr_util:media_path(kz_json:get_value(<<"Failed-Media-Name">>, JObj), 'new', UUID, JObj))/binary, $'>>,
            Tries = kz_json:get_value(<<"Media-Tries">>, JObj),
            Regex = kz_json:get_value(<<"Digits-Regex">>, JObj),
            Storage = <<"collected_digits">>,
            Data = list_to_binary([Min, " ", Max, " ", Tries, " ", Timeout, " ", Terminators, " "
                                  ,Media, " ", InvalidMedia, " ", Storage, " ", Regex]),
            {<<"play_and_get_digits">>, Data}
    end;

get_fs_app(Node, UUID, JObj, <<"record">>) ->
    case kapi_dialplan:record_v(JObj) of
        'false' -> {'error', <<"record failed to execute as JObj did not validate">>};
        'true' ->
            %% some carriers kill the channel during long recordings since there is no
            %% reverse RTP stream
            Routines = [fun(V) ->
                                case ecallmgr_config:is_true(<<"record_waste_resources">>, 'false') of
                                    'false' -> V;
                                    'true' -> [{<<"record_waste_resources">>, <<"true">>}|V]
                                end
                        end
                       ,fun(V) ->
                                case get_terminators(JObj) of
                                    'undefined' -> V;
                                    Terminators -> [Terminators|V]
                                end
                        end
                       ],
            Vars = lists:foldl(fun(F, V) -> F(V) end, [], Routines),
            _ = ecallmgr_fs_command:set(Node, UUID, Vars),

            MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
            RecordingName = ecallmgr_util:recording_filename(MediaName),
            RecArg = list_to_binary([RecordingName, " "
                                    ,kz_json:get_string_value(<<"Time-Limit">>, JObj, "20"), " "
                                    ,kz_json:get_string_value(<<"Silence-Threshold">>, JObj, "500"), " "
                                    ,kz_json:get_string_value(<<"Silence-Hits">>, JObj, "5")
                                    ]),
            {<<"record">>, RecArg}
    end;

get_fs_app(Node, UUID, JObj, <<"record_call">>) ->
    case kapi_dialplan:record_call_v(JObj) of
        'false' -> {'error', <<"record_call failed to execute as JObj did not validate">>};
        'true' -> record_call(Node, UUID, JObj)
    end;

get_fs_app(Node, UUID, JObj, <<"store">>) ->
    case kapi_dialplan:store_v(JObj) of
        'false' -> {'error', <<"store failed to execute as JObj did not validate">>};
        'true' ->
            MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
            RecordingName = ecallmgr_util:recording_filename(MediaName),
            lager:debug("streaming media ~s", [RecordingName]),
            case kz_json:get_value(<<"Media-Transfer-Method">>, JObj) of
                <<"put">> ->
                    %% stream file over HTTP PUT
                    lager:debug("stream ~s via HTTP PUT", [RecordingName]),
                    _ = stream_over_http(Node, UUID, RecordingName, 'put', 'store', JObj),
                    {<<"store">>, 'noop'};
                <<"post">> ->
                    %% stream file over HTTP POST
                    lager:debug("stream ~s via HTTP POST", [RecordingName]),
                    _ = stream_over_http(Node, UUID, RecordingName, 'post', 'store', JObj),
                    {<<"store">>, 'noop'};
                _Method ->
                    %% unhandled method
                    lager:debug("unhandled stream method ~s", [_Method]),
                    {'return', 'error'}
            end
    end;

get_fs_app(Node, UUID, JObj, <<"store_vm">>) ->
    case kapi_dialplan:store_vm_v(JObj) of
        'false' -> {'error', <<"store failed to execute as JObj did not validate">>};
        'true' ->
            MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
            RecordingName = ecallmgr_util:recording_filename(MediaName),
            lager:debug("streaming media ~s", [RecordingName]),
            case kz_json:get_value(<<"Media-Transfer-Method">>, JObj) of
                <<"put">> ->
                    %% stream file over HTTP PUT
                    lager:debug("stream ~s via HTTP PUT", [RecordingName]),
                    _ = stream_over_http(Node, UUID, RecordingName, 'put', 'store_vm', JObj),
                    {<<"store_vm">>, 'noop'};
                <<"post">> ->
                    %% stream file over HTTP POST
                    lager:debug("stream ~s via HTTP POST", [RecordingName]),
                    _ = stream_over_http(Node, UUID, RecordingName, 'post', 'store_vm', JObj),
                    {<<"store_vm">>, 'noop'};
                _Method ->
                    %% unhandled method
                    lager:debug("unhandled stream method ~s", [_Method]),
                    {'return', 'error'}
            end
    end;

get_fs_app(Node, UUID, JObj, <<"store_fax">> = App) ->
    case kapi_dialplan:store_fax_v(JObj) of
        'false' -> {'error', <<"store_fax failed to execute as JObj did not validate">>};
        'true' ->
            File = kz_json:get_value(<<"Fax-Local-Filename">>, JObj, ecallmgr_util:fax_filename(UUID)),
            lager:debug("attempting to store fax on ~s: ~s", [Node, File]),
            case kz_json:get_value(<<"Media-Transfer-Method">>, JObj) of
                <<"put">> ->
                    _ = stream_over_http(Node, UUID, File, 'put', 'fax', JObj),
                    {App, 'noop'};
                _Method ->
                    lager:debug("invalid media transfer method for storing fax: ~s", [_Method]),
                    {'error', <<"invalid media transfer method">>}
            end
    end;

get_fs_app(_Node, _UUID, JObj, <<"send_dtmf">>) ->
    case kapi_dialplan:send_dtmf_v(JObj) of
        'false' -> {'error', <<"send_dtmf failed to execute as JObj did not validate">>};
        'true' ->
            DTMFs = kz_json:get_value(<<"DTMFs">>, JObj),
            Duration = case kz_json:get_binary_value(<<"Duration">>, JObj) of
                           'undefined' -> <<>>;
                           D -> [<<"@">>, D]
                       end,
            {<<"send_dtmf">>, iolist_to_binary([DTMFs, Duration])}
    end;

get_fs_app(_Node, UUID, JObj, <<"recv_dtmf">>) ->
    case kapi_dialplan:recv_dtmf_v(JObj) of
        'false' -> {'error', <<"recv_dtmf failed to execute as JObj did not validate">>};
        'true' ->
            DTMFs = kz_json:get_value(<<"DTMFs">>, JObj),
            {<<"uuid_recv_dtmf">>, iolist_to_binary([UUID, " ", DTMFs])}
    end;

get_fs_app(Node, UUID, JObj, <<"tones">>) ->
    case kapi_dialplan:tones_v(JObj) of
        'false' -> {'error', <<"tones failed to execute as JObj did not validate">>};
        'true' ->
            'ok' = set_terminators(Node, UUID, kz_json:get_value(<<"Terminators">>, JObj)),
            Tones = kz_json:get_list_value(<<"Tones">>, JObj, []),
            tones_app(Tones)
    end;

get_fs_app(_Node, _UUID, _JObj, <<"answer">>) ->
    {<<"answer">>, <<>>};

get_fs_app(_Node, _UUID, _JObj, <<"progress">>) ->
    {<<"pre_answer">>, <<>>};

get_fs_app(_Node, _UUID, JObj, <<"privacy">>) ->
    case kapi_dialplan:privacy_v(JObj) of
        'false' -> {'error', <<"privacy failed to execute as JObj did not validate">>};
        'true' ->
            Mode = kz_json:get_ne_binary_value(<<"Privacy-Mode">>, JObj),
            {<<"privacy">>, Mode}
    end;

get_fs_app(Node, UUID, JObj, <<"ring">>) ->
    _ = case kz_json:get_value(<<"Ringback">>, JObj) of
            'undefined' -> 'ok';
            Ringback ->
                Stream = ecallmgr_util:media_path(Ringback, 'extant', UUID, JObj),
                lager:debug("custom ringback: ~s", [Stream]),
                _ = ecallmgr_fs_command:set(Node, UUID, [{<<"ringback">>, Stream}])
        end,
    {<<"ring_ready">>, <<>>};

%% receive a fax from the caller
get_fs_app(Node, UUID, JObj, <<"receive_fax">>) ->
    ecallmgr_fs_fax:receive_fax(Node, UUID, JObj);

get_fs_app(_Node, UUID, JObj, <<"hold">>) ->
    case kz_json:get_value(<<"Hold-Media">>, JObj) of
        'undefined' -> {<<"endless_playback">>, <<"${hold_music}">>};
        Media ->
            Stream = ecallmgr_util:media_path(Media, 'extant', UUID, JObj),
            lager:debug("bridge has custom music-on-hold in channel vars: ~s", [Stream]),
            {<<"endless_playback">>, Stream}
    end;

get_fs_app(_Node, UUID, JObj, <<"hold_control">>) ->
    Arg = case kz_json:get_value(<<"Action">>, JObj) of
              <<"hold">> -> <<>>;
              <<"unhold">> -> <<"off">>;
              <<"toggle">> -> <<"toggle">>
          end,
    {<<"uuid_hold">>, list_to_binary([Arg, " ", UUID])};

get_fs_app(_Node, UUID, JObj, <<"soft_hold">>) ->
    UnholdKey = kz_json:get_value(<<"Unhold-Key">>, JObj),

    AMOH = kz_json:get_value(<<"A-MOH">>, JObj, <<>>),
    BMOH = kz_json:get_value(<<"B-MOH">>, JObj, <<>>),

    AMedia = ecallmgr_util:media_path(AMOH, 'extant', UUID, JObj),
    BMedia = ecallmgr_util:media_path(BMOH, 'extant', UUID, JObj),

    {<<"soft_hold">>, list_to_binary([UnholdKey, " ", AMedia, " ", BMedia])};

get_fs_app(Node, UUID, JObj, <<"page">>) ->
    Endpoints = kz_json:get_ne_value(<<"Endpoints">>, JObj, []),
    case kapi_dialplan:page_v(JObj) of
        'false' -> {'error', <<"page failed to execute as JObj did not validate">>};
        'true' when Endpoints =:= [] -> {'error', <<"page request had no endpoints">>};
        'true' ->
            PageId = <<"page_", (kz_binary:rand_hex(8))/binary>>,
            DefaultCCV = kz_json:from_list([{<<"Auto-Answer-Suppress-Notify">>, 'true'}]),
            CCVs = kz_json:to_proplist(kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, DefaultCCV)),
            BargeParams = ecallmgr_util:multi_set_args(Node, UUID, CCVs, <<",">>, <<",">>),
            AutoAnswer = list_to_binary(["{sip_invite_params=intercom=true"
                                        ,",alert_info=intercom"
                                        ,BargeParams
                                        ,"}"
                                        ]),
            Routines = [fun(DP) ->
                                [{"application", <<"set api_hangup_hook=conference ", PageId/binary, " kick all">>}
                                ,{"application", <<"set conference_auto_outcall_profile=page">>}
                                ,{"application", <<"set conference_auto_outcall_skip_member_beep=true">>}
                                ,{"application", <<"set conference_auto_outcall_delimiter=|">>}
                                 |DP
                                ]
                        end
                       ,fun(DP) ->
                                case kz_json:is_true([<<"Page-Options">>, <<"Two-Way-Audio">>], JObj, false) of
                                    true -> DP;
                                    false -> [{"application", <<"set conference_utils_auto_outcall_flags=mute">>}
                                              | DP
                                             ]
                                end
                        end
                       ,fun(DP) ->
                                CIDName = kz_json:get_ne_value(<<"Caller-ID-Name">>, JObj, <<"${caller_id_name}">>),
                                [{"application", <<"set conference_auto_outcall_caller_id_name=", CIDName/binary>>}|DP]
                        end
                       ,fun(DP) ->
                                CIDNumber = kz_json:get_ne_value(<<"Caller-ID-Number">>, JObj, <<"${caller_id_number}">>),
                                [{"application", <<"set conference_auto_outcall_caller_id_number=", CIDNumber/binary>>}|DP]
                        end
                       ,fun(DP) ->
                                Timeout = kz_json:get_binary_value(<<"Timeout">>, JObj, <<"5">>),
                                [{"application", <<"set conference_auto_outcall_timeout=", Timeout/binary>>}|DP]
                        end
                       ,fun(DP) ->
                                {'ok', #channel{interaction_id=Id}} = ecallmgr_fs_channel:fetch(UUID, 'record'),
                                Values = [{[<<"Custom-Channel-Vars">>, <<"Auto-Answer">>], 'true'}
                                         ,{[<<"Custom-Channel-Vars">>, <<?CALL_INTERACTION_ID>>], Id}
                                         ],
                                EPs = [kz_json:set_values(Values, Endpoint) || Endpoint <- Endpoints],
                                Channels = [<<AutoAnswer/binary, Channel/binary>> || Channel <- ecallmgr_util:build_bridge_channels(EPs)],
                                OutCall = kz_binary:join(Channels, <<"|">>),
                                [{"application", <<"conference_set_auto_outcall ", OutCall/binary>>} | DP]
                        end
                       ,fun(DP) ->
                                [{"application", <<"conference ", PageId/binary, "@page">>}
                                ,{"application", <<"park">>}
                                 |DP
                                ]
                        end
                       ],
            {<<"xferext">>, lists:foldr(fun(F, DP) -> F(DP) end, [], Routines)}
    end;

get_fs_app(Node, UUID, JObj, <<"park">>) ->
    case kapi_dialplan:park_v(JObj) of
        'false' -> {'error', <<"park failed to execute as JObj did not validate">>};
        'true' ->
            maybe_set_park_timeout(Node, UUID, JObj),
            {<<"park">>, <<>>}
    end;

get_fs_app(_Node, _UUID, JObj, <<"echo">>) ->
    case kapi_dialplan:echo_v(JObj) of
        'false' -> {'error', <<"echo failed to execute as JObj did not validate">>};
        'true' -> {<<"echo">>, <<>>}
    end;

get_fs_app(_Node, _UUID, JObj, <<"sleep">>) ->
    case kapi_dialplan:sleep_v(JObj) of
        'false' -> {'error', <<"sleep failed to execute as JObj did not validate">>};
        'true' -> {<<"sleep">>, kz_json:get_binary_value(<<"Time">>, JObj, <<"50">>)}
    end;

get_fs_app(_Node, _UUID, JObj, <<"say">>) ->
    case kapi_dialplan:say_v(JObj) of
        'false' -> {'error', <<"say failed to execute as JObj did not validate">>};
        'true' ->
            Lang = say_language(kz_json:get_value(<<"Language">>, JObj)),
            Type = kz_json:get_value(<<"Type">>, JObj),
            Method = kz_json:get_value(<<"Method">>, JObj),
            Txt = kz_json:get_value(<<"Say-Text">>, JObj),
            Gender = kz_json:get_value(<<"Gender">>, JObj, <<>>),

            Arg = list_to_binary([Lang, " ", Type, " ", Method, " ", Txt, " ", Gender]),
            lager:debug("say command ~s", [Arg]),
            {<<"say">>, Arg}
    end;

get_fs_app(Node, UUID, JObj, <<"bridge">>) ->
    ecallmgr_fs_bridge:call_command(Node, UUID, JObj);

get_fs_app(_Node, UUID, JObj, <<"unbridge">>) ->
    ecallmgr_fs_bridge:unbridge(UUID, JObj);

get_fs_app(Node, UUID, JObj, <<"call_pickup">>) ->
    case kapi_dialplan:call_pickup_v(JObj) of
        'false' -> {'error', <<"intercept failed to execute as JObj did not validate">>};
        'true' -> call_pickup(Node, UUID, JObj)
    end;
get_fs_app(Node, UUID, JObj, <<"connect_leg">>) ->
    case kapi_dialplan:connect_leg_v(JObj) of
        'false' -> {'error', <<"intercept failed to execute as JObj did not validate">>};
        'true' -> connect_leg(Node, UUID, JObj)
    end;

get_fs_app(Node, UUID, JObj, <<"eavesdrop">>) ->
    case kapi_dialplan:eavesdrop_v(JObj) of
        'false' -> {'error', <<"eavesdrop failed to execute as JObj did not validate">>};
        'true' -> eavesdrop(Node, UUID, JObj)
    end;

get_fs_app(Node, UUID, JObj, <<"execute_extension">>) ->
    case kapi_dialplan:execute_extension_v(JObj) of
        'false' -> {'error', <<"execute extension failed to execute as JObj did not validate">>};
        'true' ->
            Routines = [fun execute_exten_handle_reset/4
                       ,fun execute_exten_handle_ccvs/4
                       ,fun execute_exten_pre_exec/4
                       ,fun execute_exten_create_command/4
                       ,fun execute_exten_post_exec/4
                       ],
            Extension = lists:foldr(fun(F, DP) ->
                                            F(DP, Node, UUID, JObj)
                                    end, [], Routines),
            {<<"xferext">>, Extension}
    end;

get_fs_app(Node, UUID, JObj, <<"tone_detect">>) ->
    case kapi_dialplan:tone_detect_v(JObj) of
        'false' -> {'error', <<"tone detect failed to execute as JObj did not validate">>};
        'true' ->
            Key = kz_json:get_value(<<"Tone-Detect-Name">>, JObj),
            Freqs = [ kz_term:to_list(V) || V <- kz_json:get_value(<<"Frequencies">>, JObj) ],
            FreqsStr = string:join(Freqs, ","),
            Flags = case kz_json:get_value(<<"Sniff-Direction">>, JObj, <<"read">>) of
                        <<"read">> -> <<"r">>;
                        <<"write">> -> <<"w">>
                    end,
            Timeout = kz_json:get_value(<<"Timeout">>, JObj, <<"+1000">>),
            HitsNeeded = kz_json:get_value(<<"Hits-Needed">>, JObj, <<"1">>),

            SuccessJObj = case kz_json:get_value(<<"On-Success">>, JObj, []) of
                              %% default to parking the call
                              [] ->
                                  [{<<"Application-Name">>, <<"park">>} | kz_api:extract_defaults(JObj)];
                              AppJObj ->
                                  kz_json:from_list(AppJObj ++ kz_api:extract_defaults(JObj))
                          end,

            {SuccessApp, SuccessData} = case get_fs_app(Node, UUID, SuccessJObj
                                                       ,kz_json:get_value(<<"Application-Name">>, SuccessJObj)) of
                                            %% default to park if passed app isn't right
                                            {'error', _Str} ->
                                                {<<"park">>, <<>>};
                                            {_, _}=Success ->
                                                Success
                                        end,

            Data = list_to_binary([Key, " ", FreqsStr, " ", Flags, " ", Timeout
                                  ," ", SuccessApp, " ", SuccessData, " ", HitsNeeded
                                  ]),

            {<<"tone_detect">>, Data}
    end;

get_fs_app(Node, UUID, JObj, <<"set_terminators">>) ->
    case kapi_dialplan:set_terminators_v(JObj) of
        'false' -> {'error', <<"set_terminators failed to execute as JObj did not validate">>};
        'true' ->
            'ok' = set_terminators(Node, UUID, kz_json:get_value(<<"Terminators">>, JObj)),
            {<<"set">>, 'noop'}
    end;

get_fs_app(Node, UUID, JObj, <<"set">>) ->
    case kapi_dialplan:set_v(JObj) of
        'false' -> {'error', <<"set failed to execute as JObj did not validate">>};
        'true' ->
            ChannelVars = kz_json:to_proplist(kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new())),
            CallVars = kz_json:to_proplist(kz_json:get_value(<<"Custom-Call-Vars">>, JObj, kz_json:new())),
            props:filter_undefined(
              [{<<"kz_multiset">>, case ChannelVars of
                                       [] -> 'undefined';
                                       _ -> ecallmgr_util:multi_set_args(Node, UUID, ChannelVars)
                                   end
               }
              ,{<<"kz_export">>, case CallVars of
                                     [] -> 'undefined';
                                     _ -> ecallmgr_util:multi_set_args(Node, UUID, CallVars)
                                 end
               }
              ])
    end;

get_fs_app(_Node, _UUID, JObj, <<"respond">>) ->
    case kapi_dialplan:respond_v(JObj) of
        'false' -> {'error', <<"respond failed to execute as JObj did not validate">>};
        'true' ->
            Code = kz_json:get_value(<<"Response-Code">>, JObj, ?DEFAULT_RESPONSE_CODE),
            Response = <<Code/binary ," "
                         ,(kz_json:get_value(<<"Response-Message">>, JObj, <<>>))/binary
                       >>,
            {<<"respond">>, Response}
    end;

get_fs_app(Node, UUID, JObj, <<"redirect">>) ->
    case kapi_dialplan:redirect_v(JObj) of
        'false' -> {'error', <<"redirect failed to execute as JObj did not validate">>};
        'true' ->
            RedirectServer = lookup_redirect_server(JObj) ,
            maybe_add_redirect_header(Node, UUID, RedirectServer),

            {<<"redirect">>, kz_json:get_value(<<"Redirect-Contact">>, JObj, <<>>)}
    end;

%% TODO: can we depreciate this command? It was prior to ecallmgr_fs_query....dont think anything is using it.
get_fs_app(Node, UUID, JObj, <<"fetch">>) ->
    _ = kz_util:spawn(fun send_fetch_call_event/3, [Node, UUID, JObj]),
    {<<"fetch">>, 'noop'};

get_fs_app(Node, UUID, JObj, <<"conference">>) ->
    case kapi_dialplan:conference_v(JObj) of
        'false' -> {'error', <<"conference failed to execute as JObj did not validate">>};
        'true' -> get_conference_app(Node, UUID, JObj, kz_json:is_true(<<"Reinvite">>, JObj, 'false'))
    end;

get_fs_app(_Node, _UUID, JObj, <<"fax_detection">>) ->
    case kapi_dialplan:fax_detection_v(JObj) of
        'false' -> {'error', <<"fax detect failed to execute as JObj did not validate">>};
        'true' ->
            case kz_json:get_value(<<"Action">>, JObj) of
                <<"start">> ->
                    Duration = kz_json:get_integer_value(<<"Duration">>, JObj, 3),
                    Tone = case kz_json:get_value(<<"Direction">>, JObj, <<"inbound">>) of
                               <<"inbound">> -> <<"cng">>;
                               <<"outbound">> -> <<"ced">>
                           end,
                    {<<"spandsp_start_fax_detect">>, list_to_binary(["set 'noop' ", kz_term:to_binary(Duration), " ", Tone])};
                <<"stop">> ->
                    {<<"spandsp_stop_fax_detect">>, <<>>}
            end
    end;

get_fs_app(Node, UUID, JObj, <<"transfer">>) ->
    case kapi_dialplan:transfer_v(JObj) of
        'false' -> {'error', <<"transfer failed to execute as JObj did not validate">>};
        'true' -> transfer(Node, UUID, JObj)
    end;

get_fs_app(Node, UUID, JObj, <<"media_macro">>) ->
    case kapi_dialplan:media_macro_v(JObj) of
        'false' -> {'error', <<"media macro failed to execute as JObj did not validate">>};
        'true' ->
            KVs = kz_json:foldr(
                    fun(K, Macro, Acc) ->
                            Paths = lists:map(fun ecallmgr_util:media_path/1, Macro),
                            Result = list_to_binary(["file_string://", kz_binary:join(Paths, <<"!">>)]),
                            [{K, Result} | Acc]
                    end,[], kz_json:get_value(<<"Media-Macros">>, JObj)),
            {<<"kz_multiset">>, ecallmgr_util:multi_set_args(Node, UUID, KVs, <<"|">>)}
    end;

get_fs_app(Node, UUID, JObj, <<"play_macro">>) ->
    case kapi_dialplan:play_macro_v(JObj) of
        'false' -> {'error', <<"play macro failed to execute as JObj did not validate">>};
        'true' ->
            Macro = kz_json:get_value(<<"Media-Macro">>, JObj, []),
            Paths = lists:map(fun ecallmgr_util:media_path/1, Macro),
            Result = list_to_binary(["file_string://", kz_binary:join(Paths, <<"!">>)]),
            {<<"playback">>, Result}
    end;

get_fs_app(_Node, UUID, JObj, <<"sound_touch">>) ->
    case kapi_dialplan:sound_touch_v(JObj) of
        'false' -> {'error', <<"soundtouch failed to execute as JObj did not validate">>};
        'true' -> sound_touch(UUID, kz_json:get_value(<<"Action">>, JObj), JObj)
    end;

get_fs_app(_Node, _UUID, _JObj, _App) ->
    lager:debug("unknown application ~s", [_App]),
    {'error', <<"application unknown">>}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Redirect command helpers
%% @end
%%--------------------------------------------------------------------

-spec lookup_redirect_server(kz_json:object()) -> api_binary().
lookup_redirect_server(JObj) ->
    case kz_json:get_value(<<"Redirect-Server">>, JObj) of
        'undefined' -> fixup_redirect_node(kz_json:get_value(<<"Redirect-Node">>, JObj));
        Server -> Server
    end.

-spec fixup_redirect_node(api_binary()) -> api_binary().
fixup_redirect_node('undefined') ->
    'undefined';
fixup_redirect_node(Node) ->
    SipUrl = ecallmgr_fs_node:sip_url(Node),
    binary:replace(SipUrl, <<"mod_sofia@">>, <<>>).

-spec maybe_add_redirect_header(atom(), ne_binary(), api_binary()) -> 'ok'.
maybe_add_redirect_header(_Node, _UUID, 'undefined') -> 'ok';
maybe_add_redirect_header(Node, UUID, RedirectServer) ->
    lager:debug("Set X-Redirect-Server to ~s", [RedirectServer]),
    ecallmgr_fs_command:set(Node, UUID, [{<<"sip_rh_X-Redirect-Server">>, RedirectServer}]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Eavesdrop command helpers
%% @end
%%--------------------------------------------------------------------
-spec eavesdrop(atom(), ne_binary(), kz_json:object()) ->
                       {ne_binary(), ne_binary()} |
                       {'return', ne_binary()} |
                       {'error', ne_binary()}.
eavesdrop(Node, UUID, JObj) ->
    case prepare_app(Node, UUID, JObj) of
        {'execute', AppNode, AppUUID, AppJObj, AppTarget} ->
            get_eavesdrop_app(AppNode, AppUUID, AppJObj, AppTarget);
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Call pickup command helpers
%% @end
%%--------------------------------------------------------------------
-spec call_pickup(atom(), ne_binary(), kz_json:object()) ->
                         {ne_binary(), ne_binary()} |
                         {'return', ne_binary()} |
                         {'error', ne_binary()}.
call_pickup(Node, UUID, JObj) ->
    case prepare_app(Node, UUID, JObj) of
        {'execute', AppNode, AppUUID, AppJObj, AppTarget} ->
            get_call_pickup_app(AppNode, AppUUID, AppJObj, AppTarget, <<"intercept">>);
        Other ->
            Other
    end.

-spec connect_leg(atom(), ne_binary(), kz_json:object()) ->
                         {ne_binary(), ne_binary()} |
                         {'return', ne_binary()} |
                         {'error', ne_binary()}.
connect_leg(Node, UUID, JObj) ->
    _ = ecallmgr_fs_bridge:maybe_b_leg_events(Node, UUID, JObj),
    case prepare_app(Node, UUID, JObj) of
        {'execute', AppNode, AppUUID, AppJObj, AppTarget} ->
            get_call_pickup_app(AppNode, AppUUID, AppJObj, AppTarget, <<"call_pickup">>);
        Other ->
            Other
    end.

-spec prepare_app(atom(), ne_binary(), kz_json:object() ) ->
                         {ne_binary(), ne_binary()} |
                         {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                         {'return', ne_binary()} |
                         {'error', ne_binary()}.
prepare_app(Node, UUID, JObj) ->
    Target = kz_json:get_value(<<"Target-Call-ID">>, JObj),
    prepare_app(Target, Node, UUID, JObj).

-spec prepare_app(ne_binary(), atom(), ne_binary(), kz_json:object() ) ->
                         {ne_binary(), ne_binary()} |
                         {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                         {'return', ne_binary()} |
                         {'error', ne_binary()}.
prepare_app(Target, _Node, Target, _JObj) ->
    {'error', <<"intercept target is the same as the caller">>};
prepare_app(Target, Node, UUID, JObj) ->
    case ecallmgr_fs_channel:fetch(Target, 'record') of
        {'ok', #channel{node=Node
                       ,answered=IsAnswered
                       ,interaction_id=CDR
                       }} ->
            lager:debug("target ~s is on same node(~s) as us", [Target, Node]),
            _ = ecallmgr_fs_command:set(Node, UUID, [{<<?CALL_INTERACTION_ID>>, CDR}]),
            maybe_answer(Node, UUID, IsAnswered),
            {'execute', Node, UUID, JObj, Target};
        {'ok', #channel{node=OtherNode}} ->
            lager:debug("target ~s is on other node (~s), not ~s", [Target, OtherNode, Node]),
            prepare_app_maybe_move(Node, UUID, JObj, Target, OtherNode);
        {'error', 'not_found'} ->
            lager:debug("failed to find target callid ~s locally", [Target]),
            prepare_app_via_amqp(Node, UUID, JObj, Target)
    end.

-spec prepare_app_via_amqp(atom(), ne_binary(), kz_json:object(), ne_binary()) ->
                                  {ne_binary(), ne_binary()} |
                                  {'return', ne_binary()} |
                                  {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                                  {'error', ne_binary()}.
prepare_app_via_amqp(Node, UUID, JObj, TargetCallId) ->
    case kz_amqp_worker:call_collect(
           [{<<"Call-ID">>, TargetCallId}
            | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ]
                                    ,fun(C) -> kapi_call:publish_channel_status_req(TargetCallId, C) end
                                    ,{'ecallmgr', 'true'}
          )
    of
        {'ok', JObjs} ->
            lager:debug("got response to channel query, checking if ~s is active.", [TargetCallId]),
            case prepare_app_status_filter(JObjs) of
                {'ok', Resp} ->
                    prepare_app_via_amqp(Node, UUID, JObj, TargetCallId, Resp);
                {'error', _E} ->
                    lager:debug("error querying for channels for ~s: ~p", [TargetCallId, _E]),
                    {'error', <<"failed to find target callid ", TargetCallId/binary>>}
            end;
        {'error', _E} ->
            lager:debug("error querying for channels for ~s: ~p", [TargetCallId, _E]),
            {'error', <<"failed to find target callid ", TargetCallId/binary>>}
    end.

-spec prepare_app_status_filter(kz_json:objects()) ->
                                       {'ok', kz_json:object()} |
                                       {'error', 'not_found'}.
prepare_app_status_filter([]) ->
    {'error', 'not_found'};
prepare_app_status_filter([JObj|JObjs]) ->
    %% NOTE: this prefers active calls with the assumption
    %%  that kazoo will never have a call that is active
    %%  then disconnected then active...This seems reasonable
    %%  for the foreseeable future ;)
    case kapi_call:channel_status_resp_v(JObj)
        andalso kz_json:get_value(<<"Status">>, JObj) =:= <<"active">>
    of
        'true' -> {'ok', JObj};
        'false' -> prepare_app_status_filter(JObjs)
    end.

-spec prepare_app_via_amqp(atom(), ne_binary(), kz_json:object(), ne_binary(), kz_json:object()) ->
                                  {ne_binary(), ne_binary()} |
                                  {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                                  {'return', ne_binary()}.
prepare_app_via_amqp(Node, UUID, JObj, TargetCallId, Resp) ->
    TargetNode = kz_json:get_value(<<"Switch-Nodename">>, Resp),
    lager:debug("call ~s is on ~s", [TargetCallId, TargetNode]),
    prepare_app_maybe_move_remote(Node, UUID, JObj, TargetCallId, kz_term:to_atom(TargetNode, 'true'), Resp).

-spec maybe_answer(atom(), ne_binary(), boolean()) -> 'ok'.
maybe_answer(_Node, _UUID, 'true') -> 'ok';
maybe_answer(Node, UUID, 'false') ->
    ecallmgr_util:send_cmd(Node, UUID, <<"answer">>, <<>>).

-spec prepare_app_maybe_move(atom(), ne_binary(), kz_json:object(), ne_binary(), atom()) ->
                                    {ne_binary(), ne_binary()} |
                                    {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                                    {'return', ne_binary()}.
prepare_app_maybe_move(Node, UUID, JObj, Target, OtherNode) ->
    case kz_json:is_true(<<"Move-Channel-If-Necessary">>, JObj, 'false') of
        'true' ->
            lager:debug("target ~s is on ~s, not ~s...moving", [Target, OtherNode, Node]),
            'true' = ecallmgr_channel_move:move(Target, OtherNode, Node),
            {'execute', Node, UUID, JObj, Target};
        'false' ->
            lager:debug("target ~s is on ~s, not ~s, need to redirect", [Target, OtherNode, Node]),

            _ = prepare_app_usurpers(Node, UUID),

            lager:debug("now issue the redirect to ~s", [OtherNode]),
            _ = ecallmgr_channel_redirect:redirect(UUID, OtherNode),
            {'return', <<"target is on different media server: ", (kz_term:to_binary(OtherNode))/binary>>}
    end.

-spec prepare_app_maybe_move_remote(atom(), ne_binary(), kz_json:object(), ne_binary(), atom(), kz_json:object()) ->
                                           {ne_binary(), ne_binary()} |
                                           {'execute', atom(), ne_binary(), kz_json:object(), ne_binary()} |
                                           {'return', ne_binary()}.
prepare_app_maybe_move_remote(Node, UUID, JObj, TargetCallId, TargetNode, ChannelStatusJObj) ->
    case kz_json:is_true(<<"Move-Channel-If-Necessary">>, JObj, 'false') of
        'true' ->
            lager:debug("target ~s is on ~s, not ~s...moving", [TargetCallId, TargetNode, Node]),
            'true' = ecallmgr_channel_move:move(TargetCallId, TargetNode, Node),
            {'execute', Node, UUID, JObj, TargetCallId};
        'false' ->
            lager:debug("target ~s is on ~s, not ~s, need to redirect", [TargetCallId, TargetNode, Node]),

            _ = prepare_app_usurpers(Node, UUID),

            lager:debug("now issue the redirect to ~s", [TargetNode]),
            _ = ecallmgr_channel_redirect:redirect_remote(UUID, ChannelStatusJObj),
            {'return', <<"target is on different media server: ", (kz_term:to_binary(TargetNode))/binary>>}
    end.

-spec prepare_app_usurpers(atom(), ne_binary()) -> 'ok'.
prepare_app_usurpers(Node, UUID) ->
    lager:debug("gotta usurp some fools first"),
    ControlUsurp = [{<<"Call-ID">>, UUID}
                   ,{<<"Reason">>, <<"redirect">>}
                   ,{<<"Fetch-ID">>, kz_binary:rand_hex(4)}
                    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
    PublishUsurp = [{<<"Call-ID">>, UUID}
                   ,{<<"Reference">>, kz_binary:rand_hex(4)}
                   ,{<<"Media-Node">>, kz_term:to_binary(Node)}
                   ,{<<"Reason">>, <<"redirect">>}
                    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],

    kz_amqp_worker:cast(ControlUsurp
                       ,fun(C) -> kapi_call:publish_usurp_control(UUID, C) end
                       ),
    kz_amqp_worker:cast(PublishUsurp
                       ,fun(C) -> kapi_call:publish_usurp_publisher(UUID, C) end
                       ).

-spec get_call_pickup_app(atom(), ne_binary(), kz_json:object(), ne_binary(), ne_binary()) ->
                                 {ne_binary(), ne_binary()}.
get_call_pickup_app(Node, UUID, JObj, Target, Command) ->
    ExportsApi = exports_from_api(JObj, [<<"Continue-On-Fail">>
                                        ,<<"Continue-On-Cancel">>
                                        ,<<"Hangup-After-Pickup">>
                                        ,<<"Park-After-Pickup">>
                                        ]),

    SetApi = [{<<"Unbridged-Only">>, 'undefined', <<"intercept_unbridged_only">>}
             ,{<<"Unanswered-Only">>, 'undefined', <<"intercept_unanswered_only">>}
             ,{<<"Park-After-Pickup">>, 'undefined'}
             ,{<<"Hangup-After-Pickup">>, 'undefined'}
             ],

    Exports = [{<<"failure_causes">>, <<"NORMAL_CLEARING,ORIGINATOR_CANCEL,CRASH">>}
               | build_set_args(ExportsApi, JObj)
              ],

    ControlUsurp = [{<<"Call-ID">>, Target}
                   ,{<<"Reason">>, <<"redirect">>}
                   ,{<<"Fetch-ID">>, kz_binary:rand_hex(4)}
                    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],

    case kz_json:is_true(<<"Publish-Usurp">>, JObj, 'true') of
        'true' ->
            kz_amqp_worker:cast(ControlUsurp
                               ,fun(C) -> kapi_call:publish_usurp_control(Target, C) end
                               ),
            lager:debug("published control usurp for ~s", [Target]);
        'false' ->
            lager:debug("API is skipping control usurp")
    end,

    ecallmgr_fs_command:set(Node, UUID, build_set_args(SetApi, JObj) ++ Exports),
    ecallmgr_fs_command:set(Node, UUID, Exports),
    ecallmgr_fs_command:set(Node, Target, Exports),

    {Command, Target}.

-spec exports_from_api(kz_json:object(), ne_binaries()) -> kz_proplist().
exports_from_api(JObj, Ks) ->
    props:filter_undefined(
      [{K, kz_json:get_binary_value(K, JObj)} || K <- Ks]
     ).

-spec get_eavesdrop_app(atom(), ne_binary(), kz_json:object(), ne_binary()) ->
                               {ne_binary(), ne_binary()}.
get_eavesdrop_app(Node, UUID, JObj, Target) ->
    ExportsApi = exports_from_api(JObj, [<<"Park-After-Pickup">>
                                        ,<<"Continue-On-Fail">>
                                        ,<<"Continue-On-Cancel">>
                                        ]),

    SetApi = [{<<"Enable-DTMF">>, 'undefined', <<"eavesdrop_enable_dtmf">>}
             ],

    Exports = [{<<"failure_causes">>, <<"NORMAL_CLEARING,ORIGINATOR_CANCEL,CRASH">>}
               | build_set_args(ExportsApi, JObj)
              ],

    ControlUsurp = [{<<"Call-ID">>, Target}
                   ,{<<"Reason">>, <<"redirect">>}
                   ,{<<"Fetch-ID">>, kz_binary:rand_hex(4)}
                    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
    kz_amqp_worker:cast(ControlUsurp
                       ,fun(C) -> kapi_call:publish_usurp_control(Target, C) end
                       ),
    lager:debug("published ~p for ~s~n", [ControlUsurp, Target]),

    ecallmgr_fs_command:set(Node, UUID, build_set_args(SetApi, JObj)),
    ecallmgr_fs_command:export(Node, UUID, Exports),
    {<<"eavesdrop">>, Target}.

-type set_headers() :: kz_proplist() | [{ne_binary(), api_binary(), ne_binary()},...].
-spec build_set_args(set_headers(), kz_json:object()) ->
                            kz_proplist().
-spec build_set_args(set_headers(), kz_json:object(), kz_proplist()) ->
                            kz_proplist().
build_set_args(Headers, JObj) ->
    build_set_args(Headers, JObj, []).

build_set_args([], _, Args) ->
    lists:reverse(props:filter_undefined(Args));
build_set_args([{ApiHeader, Default}|Headers], JObj, Args) ->
    build_set_args(Headers, JObj, [{kz_json:normalize_key(ApiHeader)
                                   ,kz_json:get_binary_boolean(ApiHeader, JObj, Default)
                                   } | Args
                                  ]);
build_set_args([{ApiHeader, Default, FSHeader}|Headers], JObj, Args) ->
    build_set_args(Headers, JObj, [{FSHeader
                                   ,kz_json:get_binary_boolean(ApiHeader, JObj, Default)
                                   } | Args
                                  ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Conference command helpers
%% @end
%%--------------------------------------------------------------------
get_conf_id_and_profile(JObj) ->
    ConfName = kz_json:get_value(<<"Conference-ID">>, JObj),
    ProfileName = kz_json:get_ne_value(<<"Profile">>, JObj, <<"default">>),
    {ConfName, ProfileName}.

-spec get_conference_app(atom(), ne_binary(), kz_json:object(), boolean()) ->
                                {ne_binary(), ne_binary(), atom()} |
                                {ne_binary(), 'noop' | ne_binary()}.
get_conference_app(ChanNode, UUID, JObj, 'true') ->
    {ConfName, ConferenceConfig} = get_conf_id_and_profile(JObj),
    Cmd = list_to_binary([ConfName, "@", ConferenceConfig, get_conference_flags(JObj)]),
    case ecallmgr_fs_conferences:node(ConfName) of
        {'error', 'not_found'} ->
            maybe_start_conference_on_our_node(ChanNode, UUID, JObj);
        {'ok', ChanNode} ->
            lager:debug("channel is on same node as conference"),
            ecallmgr_fs_command:export(ChanNode, UUID, [{<<"Hold-Media">>, <<"silence">>}]),
            maybe_set_nospeak_flags(ChanNode, UUID, JObj),
            {<<"conference">>, Cmd};
        {'ok', ConfNode} ->
            lager:debug("channel is on node ~s, conference is on ~s, moving channel", [ChanNode, ConfNode]),
            'true' = ecallmgr_channel_move:move(UUID, ChanNode, ConfNode),
            lager:debug("channel has moved to ~s", [ConfNode]),
            maybe_set_nospeak_flags(ConfNode, UUID, JObj),
            ecallmgr_fs_command:export(ConfNode, UUID, [{<<"Hold-Media">>, <<"silence">>}]),
            {<<"conference">>, Cmd, ConfNode}
    end;

get_conference_app(ChanNode, UUID, JObj, 'false') ->
    {ConfName, ConferenceConfig} = get_conf_id_and_profile(JObj),
    maybe_set_nospeak_flags(ChanNode, UUID, JObj),
    %% ecallmgr_fs_command:export(ChanNode, UUID, [{<<"Hold-Media">>, <<"silence">>}]),
    {<<"conference">>, list_to_binary([ConfName, "@", ConferenceConfig, get_conference_flags(JObj)])}.

-spec maybe_start_conference_on_our_node(atom(), ne_binary(), kz_json:object()) ->
                                                {ne_binary(), ne_binary(), atom()} |
                                                {ne_binary(), 'noop' | ne_binary()}.
maybe_start_conference_on_our_node(ChanNode, UUID, JObj) ->
    {ConfName, ConferenceConfig} = get_conf_id_and_profile(JObj),
    Cmd = list_to_binary([ConfName, "@", ConferenceConfig, get_conference_flags(JObj)]),

    lager:debug("conference ~s hasn't been started yet", [ConfName]),
    {'ok', _} = ecallmgr_util:send_cmd(ChanNode, UUID, "conference", Cmd),

    case wait_for_conference(ConfName) of
        {'ok', ChanNode} ->
            lager:debug("conference has started on ~s", [ChanNode]),
            maybe_set_nospeak_flags(ChanNode, UUID, JObj),
            {<<"conference">>, 'noop'};
        {'ok', OtherNode} ->
            lager:debug("conference has started on other node ~s, lets move", [OtherNode]),
            get_conference_app(ChanNode, UUID, JObj, 'true')
    end.

maybe_set_nospeak_flags(Node, UUID, JObj) ->
    case kz_json:is_true(<<"Member-Nospeak">>, JObj) of
        'false' -> 'ok';
        'true' ->
            ecallmgr_fs_command:set(Node, UUID, [{<<"conference_member_nospeak_relational">>, <<"true">>}])
    end,
    case kz_json:is_true(<<"Nospeak-Check">>, JObj) of
        'false' -> 'ok';
        'true' ->
            ecallmgr_fs_command:set(Node, UUID, [{<<"conference_member_nospeak_check">>, <<"true">>}])
    end.

%% [{FreeSWITCH-Flag-Name, Kazoo-Flag-Name}]
%% Conference-related entry flags
%% convert from FS conference flags to Kazoo conference flags
-define(CONFERENCE_FLAGS, [{<<"mute">>, <<"Mute">>}
                          ,{<<"deaf">>, <<"Deaf">>}
                          ,{<<"moderator">>, <<"Moderator">>}
                          ]).

-spec get_conference_flags(kz_json:object()) -> binary().
get_conference_flags(JObj) ->
    case kz_json:to_proplist(JObj) of
        [] -> <<>>;
        [{_Key,_Val}=KV|L] ->
            Flags = lists:foldl(fun maybe_add_conference_flag/2, [<<>>], L),
            All = case maybe_add_conference_flag(KV, []) of
                      [] -> tl(Flags);
                      [<<",">> | T] -> [T | Flags];
                      Fs -> [Fs | Flags]
                  end,
            iolist_to_binary(["+flags{", All, "}"])
    end.

maybe_add_conference_flag({K, V}, Acc) ->
    case lists:keyfind(K, 2, ?CONFERENCE_FLAGS) of
        'false' -> Acc;
        {FSFlag, _} when V =:= 'true' -> [<<",">>, FSFlag | Acc];
        _ -> Acc
    end.

-spec wait_for_conference(ne_binary()) -> {'ok', atom()}.
wait_for_conference(ConfName) ->
    case ecallmgr_fs_conferences:node(ConfName) of
        {'ok', _N}=OK -> OK;
        {'error', 'not_found'} ->
            timer:sleep(100),
            wait_for_conference(ConfName)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Store command helpers
%% @end
%%--------------------------------------------------------------------
-spec stream_over_http(atom(), ne_binary(), file:filename_all(), 'put' | 'post', 'store'| 'store_vm' | 'fax', kz_json:object()) -> any().
stream_over_http(Node, UUID, File, 'put'=Method, 'store'=Type, JObj) ->
    Url = kz_term:to_list(kz_json:get_value(<<"Media-Transfer-Destination">>, JObj)),
    lager:debug("streaming via HTTP(~s) to ~s", [Method, Url]),
    Args = list_to_binary([Url, <<" ">>, File]),
    lager:debug("execute on node ~s: http_put(~s)", [Node, Args]),
    send_fs_bg_store(Node, UUID, File, Args, Method, Type);

stream_over_http(Node, UUID, File, 'put'=Method, 'store_vm'=Type, JObj) ->
    Url = kz_term:to_list(kz_json:get_value(<<"Media-Transfer-Destination">>, JObj)),
    lager:debug("streaming via HTTP(~s) to ~s", [Method, Url]),
    Args = list_to_binary([Url, <<" ">>, File]),
    lager:debug("execute on node ~s: http_put(~s)", [Node, Args]),
    send_fs_bg_store(Node, UUID, File, Args, Method, Type);

stream_over_http(Node, UUID, File, Method, Type, JObj) ->
    Url = kz_json:get_ne_binary_value(<<"Media-Transfer-Destination">>, JObj),
    lager:debug("streaming via HTTP(~s) to ~s", [Method, Url]),
    ecallmgr_fs_command:set(Node, UUID, [{<<"Recording-URL">>, Url}]),
    Args = <<Url/binary, " ", File/binary>>,
    lager:debug("execute on node ~s: http_put(~s)", [Node, Args]),
    SendAlert = kz_json:is_true(<<"Suppress-Error-Report">>, JObj, 'false'),
    Result = case send_fs_store(Node, Args, Method) of
                 {'ok', <<"+OK", _/binary>>} ->
                     lager:debug("successfully stored media for ~s", [Type]),
                     <<"success">>;
                 {'ok', Err} ->
                     lager:debug("store media failed for ~s: ~s", [Type, Err]),
                     maybe_send_detailed_alert(SendAlert, Node, UUID, File, Type, Err),
                     <<"failure">>;
                 {'error', E} ->
                     lager:debug("error executing http_put for ~s: ~p", [Type, E]),
                     maybe_send_detailed_alert(SendAlert, Node, UUID, File, Type, E),
                     <<"failure">>
             end,
    case Type of
        'store' -> send_store_call_event(Node, UUID, Result);
        'fax' -> send_store_fax_call_event(UUID, Result)
    end.

-spec maybe_send_detailed_alert(boolean(), atom(), ne_binary(), ne_binary(), 'store' | 'fax', any()) -> any().
maybe_send_detailed_alert('true', _, _, _, _, _) -> 'ok';
maybe_send_detailed_alert(_, Node, UUID, File, Type, Reason) ->
    send_detailed_alert(Node, UUID, File, Type, Reason).

-spec send_detailed_alert(atom(), ne_binary(), ne_binary(), 'store' | 'fax', any()) -> any().
send_detailed_alert(Node, UUID, File, Type, Reason) ->
    kz_notify:detailed_alert("Failed to store ~s: media file ~s for call ~s on ~s "
                            ,[Type, File, UUID, Node]
                            ,[{<<"Details">>, Reason}]
                            ).

-spec send_fs_store(atom(), ne_binary(), 'put' | 'post') -> fs_api_ret().
send_fs_store(Node, Args, 'put') ->
    freeswitch:api(Node, 'http_put', kz_term:to_list(Args), 120 * ?MILLISECONDS_IN_SECOND);
send_fs_store(Node, Args, 'post') ->
    freeswitch:api(Node, 'http_post', kz_term:to_list(Args), 120 * ?MILLISECONDS_IN_SECOND).

-spec send_fs_bg_store(atom(), ne_binary(), ne_binary(), ne_binary(), 'put' | 'post', 'store' | 'store_vm' | 'fax') -> fs_api_ret().
send_fs_bg_store(Node, UUID, File, Args, 'put', 'store') ->
    case freeswitch:bgapi(Node, UUID, [File], 'http_put', kz_term:to_list(Args), fun chk_store_result/6) of
        {'error', _} -> send_store_call_event(Node, UUID, <<"failure">>);
        {'ok', JobId} -> lager:debug("bgapi started ~p", [JobId])
    end;
send_fs_bg_store(Node, UUID, File, Args, 'put', 'store_vm') ->
    case freeswitch:bgapi(Node, UUID, [File], 'http_put', kz_term:to_list(Args), fun chk_store_vm_result/6) of
        {'error', _} -> send_store_vm_call_event(Node, UUID, <<"failure">>);
        {'ok', JobId} -> lager:debug("bgapi started ~p", [JobId])
    end.

-spec chk_store_result(atom(), atom(), ne_binary(), list(), ne_binary(), binary()) -> 'ok'.
chk_store_result(Res, Node, UUID, [File], JobId, <<"+OK", _/binary>>=Reply) ->
    lager:debug("chk_store_result ~p : ~p : ~p", [Res, JobId, Reply]),
    send_store_call_event(Node, UUID, {<<"success">>, File});
chk_store_result(Res, Node, UUID, [File], JobId, Reply) ->
    lager:debug("chk_store_result ~p : ~p : ~p", [Res, JobId, Reply]),
    send_store_call_event(Node, UUID, {<<"failure">>, File}).

-spec chk_store_vm_result(atom(), atom(), ne_binary(), list(), ne_binary(), binary()) -> 'ok'.
chk_store_vm_result(Res, Node, UUID, _, JobId, <<"+OK", _/binary>>=Reply) ->
    lager:debug("chk_store_result ~p : ~p : ~p", [Res, JobId, Reply]),
    send_store_vm_call_event(Node, UUID, <<"success">>);
chk_store_vm_result(Res, Node, UUID, _, JobId, Reply) ->
    lager:debug("chk_store_result ~p : ~p : ~p", [Res, JobId, Reply]),
    send_store_vm_call_event(Node, UUID, <<"failure">>).

-spec send_store_call_event(atom(), ne_binary(), kz_json:object() | ne_binary() | {ne_binary(), api_binary()}) -> 'ok'.
send_store_call_event(Node, UUID, {MediaTransResults, File}) ->
    ChannelProps =
        case ecallmgr_fs_channel:channel_data(Node, UUID) of
            {'ok', Ps} -> Ps;
            {'error', _Err} -> []
        end,

    BaseProps = build_base_store_event_props(UUID, ChannelProps, MediaTransResults, File, <<"store">>),
    ApiProps = maybe_add_ccvs(BaseProps, ChannelProps),
    kz_amqp_worker:cast(ApiProps, fun kapi_call:publish_event/1);
send_store_call_event(Node, UUID, MediaTransResults) ->
    send_store_call_event(Node, UUID, {MediaTransResults, 'undefined'}).

-spec maybe_add_ccvs(kz_proplist(), kz_proplist()) -> kz_proplist().
maybe_add_ccvs(BaseProps, ChannelProps) ->
    case ecallmgr_util:custom_channel_vars(ChannelProps) of
        [] -> BaseProps;
        CustomProp ->
            props:set_value(<<"Custom-Channel-Vars">>
                           ,kz_json:from_list(CustomProp)
                           ,BaseProps
                           )
    end.

-spec build_base_store_event_props(ne_binary(), kz_proplist(), ne_binary(), api_binary(), ne_binary()) -> kz_proplist().
build_base_store_event_props(UUID, ChannelProps, MediaTransResults, File, App) ->
    Timestamp = kz_term:to_binary(kz_time:now_s()),
    props:filter_undefined(
      [{<<"Msg-ID">>, props:get_value(<<"Event-Date-Timestamp">>, ChannelProps, Timestamp)}
      ,{<<"Call-ID">>, UUID}
      ,{<<"Call-Direction">>, kzd_freeswitch:call_direction(ChannelProps)}
      ,{<<"Channel-Call-State">>, props:get_value(<<"Channel-Call-State">>, ChannelProps, <<"HANGUP">>)}
      ,{<<"Application-Name">>, App}
      ,{<<"Application-Response">>, MediaTransResults}
      ,{<<"Application-Data">>, File}
       | kz_api:default_headers(<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>, ?APP_NAME, ?APP_VERSION)
      ]).

-spec send_store_vm_call_event(atom(), ne_binary(), kz_json:object() | ne_binary()) -> 'ok'.
send_store_vm_call_event(Node, UUID, MediaTransResults) ->
    ChannelProps =
        case ecallmgr_fs_channel:channel_data(Node, UUID) of
            {'ok', Ps} -> Ps;
            {'error', _Err} -> []
        end,

    BaseProps = build_base_store_event_props(UUID, ChannelProps, MediaTransResults, 'undefined', <<"store_vm">>),
    ApiProps = maybe_add_ccvs(BaseProps, ChannelProps),

    kz_amqp_worker:cast(ApiProps, fun kapi_call:publish_event/1).

-spec send_store_fax_call_event(ne_binary(), ne_binary()) -> 'ok'.
send_store_fax_call_event(UUID, Results) ->
    Timestamp = kz_term:to_binary(kz_time:now_s()),
    Prop = [{<<"Msg-ID">>, Timestamp}
           ,{<<"Call-ID">>, UUID}
           ,{<<"Application-Name">>, <<"store_fax">>}
           ,{<<"Application-Response">>, Results}
            | kz_api:default_headers(<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>, ?APP_NAME, ?APP_VERSION)
           ],
    kz_amqp_worker:cast(Prop, fun kapi_call:publish_event/1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec find_fetch_channel_data(atom(), ne_binary(), kz_json:object()) ->
                                     {'ok', kz_proplist()}.
find_fetch_channel_data(Node, UUID, JObj) ->
    case kz_json:is_true(<<"From-Other-Leg">>, JObj) of
        'true' ->
            {'ok', OtherUUID} = freeswitch:api(Node, 'uuid_getvar', kz_term:to_list(<<UUID/binary, " bridge_uuid">>)),
            ecallmgr_fs_channel:channel_data(Node, OtherUUID);
        'false' ->
            ecallmgr_fs_channel:channel_data(Node, UUID)
    end.

-spec send_fetch_call_event(atom(), ne_binary(), kz_json:object()) -> 'ok'.
send_fetch_call_event(Node, UUID, JObj) ->
    try
        {'ok', ChannelProps} = find_fetch_channel_data(Node, UUID, JObj),
        BaseProps = base_fetch_call_event_props(UUID, ChannelProps),
        ApiProps = maybe_add_ccvs(BaseProps, ChannelProps),
        kz_amqp_worker:cast(ApiProps, fun kapi_call:publish_event/1)
    catch
        Type:_ ->
            Error = base_fetch_error_event_props(UUID, JObj, Type),
            kz_amqp_worker:cast(Error, fun(E) -> kapi_dialplan:publish_error(UUID, E) end)
    end.

-spec base_fetch_error_event_props(ne_binary(), kz_json:object(), atom()) ->
                                          kz_proplist().
base_fetch_error_event_props(UUID, JObj, Type) ->
    props:filter_undefined(
      [{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, JObj)}
      ,{<<"Error-Message">>, <<"failed to construct or publish fetch call event">>}
      ,{<<"Call-ID">>, UUID}
      ,{<<"Application-Name">>, <<"fetch">>}
      ,{<<"Application-Response">>, <<>>}
       | kz_api:default_headers(<<"error">>, kz_term:to_binary(Type), ?APP_NAME, ?APP_VERSION)
      ]).

-spec base_fetch_call_event_props(ne_binary(), kz_proplist()) ->
                                         kz_proplist().
base_fetch_call_event_props(UUID, ChannelProps) ->
    props:filter_undefined(
      [{<<"Msg-ID">>, props:get_value(<<"Event-Date-Timestamp">>, ChannelProps)}
      ,{<<"Call-ID">>, UUID}
      ,{<<"Call-Direction">>, kzd_freeswitch:call_direction(ChannelProps)}
      ,{<<"Channel-Call-State">>, props:get_value(<<"Channel-Call-State">>, ChannelProps)}
      ,{<<"Application-Name">>, <<"fetch">>}
      ,{<<"Application-Response">>, <<>>}
       | kz_api:default_headers(<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>, ?APP_NAME, ?APP_VERSION)
      ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Execute extension helpers
%% @end
%%--------------------------------------------------------------------
execute_exten_handle_reset(DP, Node, UUID, JObj) ->
    case kz_json:is_true(<<"Reset">>, JObj) of
        'false' -> ok;
        'true' ->
            create_dialplan_move_ccvs(Node, UUID, DP)
    end.

execute_exten_handle_ccvs(DP, _Node, UUID, JObj) ->
    CCVs = kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
    case kz_json:is_empty(CCVs) of
        'true' -> DP;
        'false' ->
            ChannelVars = kz_json:to_proplist(CCVs),
            [{"application", <<"set ", (ecallmgr_util:get_fs_kv(K, V, UUID))/binary>>}
             || {K, V} <- ChannelVars] ++ DP
    end.

execute_exten_pre_exec(DP, _Node, _UUID, _JObj) ->
    [{"application", <<"set ", ?CHANNEL_VAR_PREFIX, "Executing-Extension=true">>}
     | DP
    ].

execute_exten_create_command(DP, _Node, _UUID, JObj) ->
    [{"application", <<"execute_extension ", (kz_json:get_value(<<"Extension">>, JObj))/binary>>}
     |DP
    ].

execute_exten_post_exec(DP, _Node, _UUID, _JObj) ->
    [{"application", <<"unset ", ?CHANNEL_VAR_PREFIX, "Executing-Extension">>}
    ,{"application", ecallmgr_util:create_masquerade_event(<<"execute_extension">>
                                                          ,<<"CHANNEL_EXECUTE_COMPLETE">>
                                                          )}
    ,{"application", "park "}
     |DP
    ].

-spec create_dialplan_move_ccvs(atom(), ne_binary(), kz_proplist()) -> kz_proplist().
create_dialplan_move_ccvs(Node, UUID, DP) ->
    case ecallmgr_fs_channel:channel_data(Node, UUID) of
        {'ok', Props} ->
            create_dialplan_move_ccvs(DP, Props);
        {'error', _E} ->
            lager:debug("failed to create ccvs for move, no channel data for ~s: ~p", [UUID, _E]),
            DP
    end.

-spec create_dialplan_move_ccvs(kz_proplist(), kz_proplist()) -> kz_proplist().
create_dialplan_move_ccvs(DP, Props) ->
    lists:foldr(
      fun({<<"variable_", ?CHANNEL_VAR_PREFIX, Key/binary>>, Val}, Acc) ->
              [{"application", <<"unset ", ?CHANNEL_VAR_PREFIX, Key/binary>>}
              ,{"application", <<"set ", ?CHANNEL_VAR_PREFIX, ?CHANNEL_VARS_EXT ,Key/binary, "=", Val/binary>>}
               |Acc
              ];
         ({<<?CHANNEL_VAR_PREFIX, K/binary>> = Key, Val}, Acc) ->
              [{"application", <<"unset ", Key/binary>>}
              ,{"application", <<"set ", ?CHANNEL_VAR_PREFIX, ?CHANNEL_VARS_EXT, K/binary, "=", Val/binary>>}
               |Acc
              ];
         ({<<"variable_sip_h_X-", Key/binary>>, Val}, Acc) ->
              [{"application", <<"unset sip_h_X-", Key/binary>>}
              ,{"application", <<"set sip_h_X-", ?CHANNEL_VARS_EXT ,Key/binary, "=", Val/binary>>}
               |Acc
              ];
         ({<<"sip_h_X-", Key/binary>>, Val}, Acc) ->
              [{"application", <<"unset sip_h_X-", Key/binary>>}
              ,{"application", <<"set sip_h_X-", ?CHANNEL_VARS_EXT ,Key/binary, "=", Val/binary>>}
               |Acc
              ];
         (_, Acc) -> Acc
      end
               ,DP
               ,Props
     ).

-spec tts(atom(), ne_binary(), kz_json:object()) ->
                 {ne_binary(), ne_binary()}.
tts(Node, UUID, JObj) ->
    'ok' = set_terminators(Node, UUID, kz_json:get_value(<<"Terminators">>, JObj)),

    case kz_json:get_value(<<"Engine">>, JObj, <<"flite">>) of
        <<"flite">> -> ecallmgr_fs_flite:call_command(Node, UUID, JObj);
        _Engine ->
            SayMe = kz_json:get_value(<<"Text">>, JObj),

            Voice = kz_json:get_value(<<"Voice">>, JObj, kazoo_tts:default_voice()),
            Language = kz_json:get_value(<<"Language">>, JObj, kazoo_tts:default_language()),
            TTSId = kz_binary:md5(<<SayMe/binary, "/", Voice/binary, "/", Language/binary>>),

            lager:debug("using engine ~s to say: ~s (tts_id: ~s)", [_Engine, SayMe, TTSId]),

            TTS = <<"tts://", TTSId/binary>>,
            case ecallmgr_util:media_path(TTS, UUID, JObj) of
                TTS ->
                    lager:debug("failed to fetch a playable media, reverting to flite"),
                    get_fs_app(Node, UUID, kz_json:set_value(<<"Engine">>, <<"flite">>, JObj), <<"tts">>);
                MediaPath ->
                    lager:debug("got media path ~s", [MediaPath]),
                    play(Node, UUID, kz_json:set_value(<<"Media-Name">>, MediaPath, JObj))
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Playback command helpers
%% @end
%%--------------------------------------------------------------------
-spec play(atom(), ne_binary(), kz_json:object()) -> fs_apps().
play(Node, UUID, JObj) ->
    [play_vars(Node, UUID, JObj)
    ,play_app(UUID, JObj)
    ].

-spec play_app(ne_binary(), kz_json:object()) -> fs_app().
play_app(UUID, JObj) ->
    MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
    F = ecallmgr_util:media_path(MediaName, 'new', UUID, JObj),
    %% if Leg is set, use uuid_broadcast; otherwise use playback
    case ecallmgr_fs_channel:is_bridged(UUID) of
        'false' -> {<<"playback">>, F};
        'true' -> play_bridged(UUID, JObj, F)
    end.

-spec play_bridged(ne_binary(), kz_json:object(), ne_binary()) -> fs_app().
play_bridged(UUID, JObj, F) ->
    case kz_json:get_value(<<"Leg">>, JObj) of
        <<"self">> ->  {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' aleg">>])};
        <<"A">> ->     {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' aleg">>])};
        <<"peer">> ->  {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' bleg">>])};
        <<"B">> ->     {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' bleg">>])};
        <<"Both">> ->  {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' both">>])};
        'undefined' -> {<<"broadcast">>, list_to_binary([UUID, " '", F, <<"' both">>])}
    end.

-spec play_vars(atom(), ne_binary(), kz_json:object()) -> fs_app().
play_vars(Node, UUID, JObj) ->
    Routines = [fun(V) ->
                        case kz_json:get_value(<<"Group-ID">>, JObj) of
                            'undefined' -> V;
                            GID -> [{<<"media_group_id">>, GID}|V]
                        end
                end
               ,fun(V) ->
                        case get_terminators(JObj) of
                            'undefined' -> V;
                            Terminators -> [Terminators|V]
                        end
                end
               ],
    Vars = lists:foldl(fun(F, V) -> F(V) end, [], Routines),
    Args = ecallmgr_util:process_fs_kv(Node, UUID, Vars, 'set'),
    {<<"kz_multiset">>, ecallmgr_util:fs_args_to_binary(Args)}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_terminators(api_binary() | ne_binaries() | kz_json:object()) ->
                             {ne_binary(), ne_binary()} | 'undefined'.
get_terminators('undefined') -> 'undefined';
get_terminators(Ts) when is_binary(Ts) -> get_terminators([Ts]);
get_terminators([_|_]=Ts) ->
    case Ts =:= get('$prior_terminators') of
        'true' -> 'undefined';
        'false' ->
            put('$prior_terminators', Ts),
            case kz_term:is_empty(Ts) of
                'true' ->  {<<"playback_terminators">>, <<"none">>};
                'false' -> {<<"playback_terminators">>, kz_term:to_binary(Ts)}
            end
    end;
get_terminators(JObj) -> get_terminators(kz_json:get_ne_value(<<"Terminators">>, JObj)).

-spec set_terminators(atom(), ne_binary(), api_binary() | ne_binaries()) ->
                             ecallmgr_util:send_cmd_ret().
set_terminators(Node, UUID, Ts) ->
    case get_terminators(Ts) of
        'undefined' -> 'ok';
        {K, V} ->
            case ecallmgr_fs_command:set(Node, UUID, [{K, V}]) of
                {'ok', _} -> 'ok';
                E -> E
            end
    end.

%% FreeSWITCH 'say' or 'say_string' may support more, but for now, map to the primary language
say_language('undefined') -> <<"en">>;
say_language(<<_:2/binary>> = Lang) -> Lang;
say_language(<<Lang:2/binary, _/binary>>) -> Lang.

-spec maybe_set_park_timeout(atom(), ne_binary(), kz_json:object()) -> 'ok'.
maybe_set_park_timeout(Node, UUID, JObj) ->
    case kz_json:get_integer_value(<<"Timeout">>, JObj) of
        'undefined' -> 'ok';
        Timeout ->
            ParkTimeout =
                case kz_json:get_value(<<"Hangup-Cause">>, JObj) of
                    'undefined' -> kz_term:to_binary(Timeout);
                    Cause ->
                        [kz_term:to_binary(Timeout), ":", Cause]
                end,
            ecallmgr_fs_command:set(Node, UUID, [{<<"park_timeout">>, ParkTimeout}])
    end.

-spec record_call(atom(), ne_binary(), kz_json:object()) -> fs_app().
record_call(Node, UUID, JObj) ->
    Action = kz_json:get_value(<<"Record-Action">>, JObj),
    record_call(Node, UUID, Action, JObj).

-spec record_call(atom(), ne_binary(), ne_binary(), kz_json:object()) -> fs_app().
record_call(Node, UUID, <<"start">>, JObj) ->
    Vars = props:filter_undefined(record_call_vars(JObj)),
    Args = ecallmgr_util:process_fs_kv(Node, UUID, Vars, 'set'),
    AppArgs = ecallmgr_util:fs_args_to_binary(Args),

    MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
    RecordingName = ecallmgr_util:recording_filename(MediaName),
    RecodingBaseName = filename:basename(RecordingName),
    RecordingId = kz_json:get_value(<<"Media-Recording-ID">>, JObj),

    [{<<"kz_multiset">>, AppArgs}
    ,{<<"unshift">>, <<"media_recordings,", RecordingName/binary>>}
    ,{<<"unshift">>, <<(?CCV(<<"Media-Names">>))/binary, ",", RecodingBaseName/binary>>}
    ,{<<"unshift">>, <<(?CCV(<<"Media-Recordings">>))/binary, ",", RecordingId/binary>>}
    ,{<<"record_session">>, RecordingName}
    ];
record_call(_Node, _UUID, <<"stop">>, JObj) ->
    RecordingName = case kz_json:get_value(<<"Media-Name">>, JObj) of
                        'undefined' -> <<"${media_recordings[0]}">>;
                        MediaName -> ecallmgr_util:recording_filename(MediaName)
                    end,
    {<<"stop_record_session">>, RecordingName}.

-spec record_call_vars(kz_json:object()) -> kz_proplist().
record_call_vars(JObj) ->
    Routines = [fun maybe_waste_resources/1
               ,fun(Acc) -> maybe_get_terminators(Acc, JObj) end
               ],

    FollowTransfer = kz_json:get_binary_boolean(<<"Follow-Transfer">>, JObj, <<"true">>),
    RecordMinSec = kz_json:get_binary_value(<<"Record-Min-Sec">>, JObj),
    SampleRate = get_sample_rate(JObj),

    lists:foldl(fun(F, V) -> F(V) end
               ,[{<<"RECORD_APPEND">>, <<"true">>}
                ,{<<"enable_file_write_buffering">>, <<"false">>}
                ,{<<"RECORD_STEREO">>, should_record_stereo(JObj)}
                ,{<<"RECORD_SOFTWARE">>, ?RECORD_SOFTWARE}
                ,{<<"recording_follow_transfer">>, FollowTransfer}
                ,{<<"recording_follow_attxfer">>, FollowTransfer}
                ,{<<"Record-Min-Sec">>, RecordMinSec}
                ,{<<"record_sample_rate">>, kz_term:to_binary(SampleRate)}
                ,{<<"Media-Recorder">>, kz_json:get_value(<<"Media-Recorder">>, JObj)}
                ,{<<"Time-Limit">>, kz_json:get_value(<<"Time-Limit">>, JObj)}
                ,{<<"Media-Name">>, kz_json:get_value(<<"Media-Name">>, JObj)}
                ,{<<"Media-Recording-ID">>, kz_json:get_value(<<"Media-Recording-ID">>, JObj)}
                ,{<<"Media-Recording-Endpoint-ID">>, kz_json:get_value(<<"Media-Recording-Endpoint-ID">>, JObj)}
                ,{<<"Media-Recording-Origin">>, kz_json:get_value(<<"Media-Recording-Origin">>, JObj)}
                ]
               ,Routines
               ).

-spec maybe_waste_resources(kz_proplist()) -> kz_proplist().
maybe_waste_resources(Acc) ->
    case ecallmgr_config:is_true(<<"record_waste_resources">>, 'false') of
        'false' -> Acc;
        'true' -> [{<<"record_waste_resources">>, <<"true">>} | Acc]
    end.

-spec maybe_get_terminators(kz_proplist(), kz_json:object()) -> kz_proplist().
maybe_get_terminators(Acc, JObj) ->
    case get_terminators(JObj) of
        'undefined' -> Acc;
        Terminators -> [Terminators|Acc]
    end.

-spec should_record_stereo(kz_json:object()) -> ne_binary().
should_record_stereo(JObj) ->
    case kz_json:is_true(<<"Channels-As-Stereo">>, JObj, 'true') of
        'true'  -> <<"true">>;
        'false' -> <<"false">>
    end.

-spec get_sample_rate(kz_json:object()) -> pos_integer().
get_sample_rate(JObj) ->
    case kz_json:get_integer_value(<<"Record-Sample-Rate">>, JObj) of
        'undefined' -> get_default_sample_rate(JObj);
        SampleRate -> SampleRate
    end.

-spec get_default_sample_rate(kz_json:object()) -> pos_integer().
get_default_sample_rate(JObj) ->
    case should_record_stereo(JObj) of
        <<"true">> -> ?DEFAULT_STEREO_SAMPLE_RATE;
        <<"false">> -> ?DEFAULT_SAMPLE_RATE
    end.

-spec tones_app(kz_json:objects()) -> {ne_binary(), iodata()}.
tones_app(Tones) ->
    FSTones = [tone_to_fs_tone(Tone) || Tone <- Tones],
    Arg = "tone_stream://" ++ string:join(FSTones, ";"),
    {<<"playback">>, Arg}.

-spec tone_to_fs_tone(kz_json:object()) -> string().
tone_to_fs_tone(Tone) ->
    Vol = tone_volume(Tone),
    Repeat = tone_repeat(Tone),
    Freqs = tone_frequencies(Tone),

    On = tone_duration_on(Tone),
    Off = tone_duration_off(Tone),

    kz_term:to_list(
      list_to_binary([Vol, Repeat, "%(", On, ",", Off, ",", Freqs, ")"])
     ).

-spec tone_volume(kz_json:object()) -> binary().
tone_volume(Tone) ->
    case kz_json:get_value(<<"Volume">>, Tone) of
        'undefined' -> <<>>;
        %% need to map V (0-100) to FS values
        V -> list_to_binary(["v=", kz_term:to_list(V), ";"])
    end.

-spec tone_repeat(kz_json:object()) -> binary().
tone_repeat(Tone) ->
    case kz_json:get_value(<<"Repeat">>, Tone) of
        'undefined' -> <<>>;
        R -> list_to_binary(["l=", kz_term:to_list(R), ";"])
    end.

-spec tone_frequencies(kz_json:object()) -> ne_binary().
tone_frequencies(Tone) ->
    kz_binary:join(
      [kz_term:to_binary(V)
       || V <- kz_json:get_value(<<"Frequencies">>, Tone, [])
      ]
                  ,<<",">>
     ).

-spec tone_duration_on(kz_json:object()) -> ne_binary().
tone_duration_on(Tone) ->
    kz_json:get_binary_value(<<"Duration-ON">>, Tone).

-spec tone_duration_off(kz_json:object()) -> ne_binary().
tone_duration_off(Tone) ->
    kz_json:get_binary_value(<<"Duration-OFF">>, Tone).

-spec transfer(atom(), ne_binary(), kz_json:object()) -> {ne_binary(), ne_binary()}.
transfer(Node, UUID, JObj) ->
    TransferType = kz_json:get_value(<<"Transfer-Type">>, JObj),
    TransferTo = kz_json:get_value(<<"Transfer-To">>, JObj),
    transfer(Node, UUID, TransferType, TransferTo, JObj).

-spec transfer(atom(), ne_binary(), ne_binary(), ne_binary(), kz_json:object()) -> {ne_binary(), ne_binary()}.
transfer(Node, UUID, <<"attended">>, TransferTo, JObj) ->
    CCVs = kz_json:to_proplist(kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new())),
    CCVList = [<<"Account-ID">>
              ,<<"Authorizing-ID">>
              ,<<"Authorizing-Type">>
              ,<<"Channel-Authorized">>
              ],
    Realm = props:get_first_defined([<<"Account-Realm">>, <<"Realm">>], CCVs, <<"norealm">>),
    ReqURI = <<TransferTo/binary, "@", Realm/binary>>,
    Vars = props:filter_undefined(
             [{<<"Ignore-Early-Media">>, <<"ring_ready">>}
             ,{<<"Simplify-Loopback">>, <<"false">>}
             ,{<<"Loopback-Bowout">>, <<"true">>}
             ,{<<"Loopback-Request-URI">>, ReqURI}
             ,{<<"SIP-Invite-Domain">>, Realm}
             ,{<<"Outbound-Caller-ID-Number">>, kz_json:get_value(<<"Caller-ID-Number">>, JObj)}
             ,{<<"Outbound-Caller-ID-Name">>, kz_json:get_value(<<"Caller-ID-Name">>, JObj)}
             ,{<<"Outbound-Callee-ID-Number">>, TransferTo}
             ,{<<"Outbound-Callee-ID-Name">>, TransferTo}
             ]),
    Props = [KV || {K,_V} = KV <- CCVs,
                   lists:member(K, CCVList)
            ]  ++ Vars,
    [Export | Exports] = ecallmgr_util:process_fs_kv(Node, UUID, Props, 'set'),
    Arg = [Export, [[",", Exported] || Exported <- Exports] ],
    {<<"att_xfer">>, list_to_binary(["{", Arg, "}loopback/", TransferTo, <<"/">>, transfer_context(JObj)])};
transfer(Node, UUID, <<"blind">>, TransferTo, JObj) ->
    Realm = transfer_realm(UUID),
    TransferLeg = transfer_leg(JObj),
    TargetUUID = transfer_set_callid(UUID, TransferLeg),
    KVs = props:filter_undefined(
            [{<<"SIP-Refer-To">>, <<"<sip:", TransferTo/binary, "@", Realm/binary>>}
            ,{<<"SIP-Referred-By">>, transfer_referred(UUID, TransferLeg)}
            ]),
    Args = kz_binary:join(ecallmgr_util:process_fs_kv(Node, TargetUUID, KVs, 'set'), <<";">>),
    [{<<"kz_uuid_setvar_multi">>, list_to_binary([TargetUUID, " ", Args])}
    ,{<<"blind_xfer">>, list_to_binary([TransferLeg, " ", TransferTo, <<" XML ">>, transfer_context(JObj)])}
    ].

-spec transfer_realm(ne_binary()) -> ne_binary().
transfer_realm(UUID) ->
    case ecallmgr_fs_channel:fetch(UUID, 'record') of
        {'ok', #channel{realm=Realm}} -> Realm;
        _Else -> <<"norealm">>
    end.

-spec transfer_set_callid(ne_binary(), binary()) -> ne_binary().
transfer_set_callid(UUID, <<"-bleg">>) ->
    case ecallmgr_fs_channel:fetch(UUID, 'record') of
        {'ok', #channel{other_leg='undefined'}} -> UUID;
        {'ok', #channel{other_leg=OtherUUID}} -> OtherUUID;
        _ -> UUID
    end;
transfer_set_callid(UUID, _) -> UUID.

-spec transfer_referred(ne_binary(), binary()) -> api_binary().
transfer_referred(UUID, <<"-bleg">>) ->
    case ecallmgr_fs_channel:fetch(UUID, 'record') of
        {'ok', #channel{presence_id='undefined'}} -> 'undefined';
        {'ok', #channel{presence_id=PresenceId}} -> <<"<sip:", PresenceId/binary, ">">>;
        _Else -> 'undefined'
    end;
transfer_referred(UUID, _) ->
    case ecallmgr_fs_channel:fetch_other_leg(UUID, 'record') of
        {'ok', #channel{presence_id='undefined'}} -> 'undefined';
        {'ok', #channel{presence_id=PresenceId}} -> <<"<sip:", PresenceId/binary, ">">>;
        _Else -> 'undefined'
    end.

-spec transfer_leg(kz_json:object()) -> binary().
transfer_leg(JObj) ->
    case kz_json:get_value(<<"Transfer-Leg">>, JObj) of
        'undefined' -> <<>>;
        TransferLeg -> <<"-", TransferLeg/binary>>
    end.

-spec transfer_context(kz_json:object()) -> binary().
transfer_context(JObj) ->
    kz_json:get_value(<<"Transfer-Context">>, JObj, ?DEFAULT_FREESWITCH_CONTEXT).

-spec sound_touch(ne_binary(), ne_binary(), kz_json:object()) -> {ne_binary(), ne_binary()}.
sound_touch(UUID, <<"start">>, JObj) ->
    {<<"soundtouch">>, list_to_binary([UUID, " start ", sound_touch_options(JObj)])};
sound_touch(UUID, <<"stop">>, _JObj) ->
    {<<"soundtouch">>, list_to_binary([UUID, " stop"])}.

-spec sound_touch_options(kz_json:object()) -> binary().
sound_touch_options(JObj) ->
    Options = [{<<"Sending-Leg">>, fun(V, L) -> case kz_term:is_true(V) of
                                                    'true' -> [<<"send_leg">> | L];
                                                    'false' -> L
                                                end
                                   end
               }
              ,{<<"Hook-DTMF">>, fun(V, L) -> case kz_term:is_true(V) of
                                                  'true' -> [<<"hook_dtmf">> | L];
                                                  'false' -> L
                                              end
                                 end
               }
              ,{<<"Adjust-In-Semitones">>, fun(V, L) -> [io_lib:format("~ss", [V]) | L] end}
              ,{<<"Adjust-In-Octaves">>, fun(V, L) -> [io_lib:format("~so", [V]) | L] end}
              ,{<<"Pitch">>, fun(V, L) -> [io_lib:format("~so", [V]) | L] end}
              ,{<<"Rate">>, fun(V, L) -> [io_lib:format("~so", [V]) | L] end}
              ,{<<"Tempo">>, fun(V, L) -> [io_lib:format("~so", [V]) | L] end}
              ],
    {Args, _} = lists:foldl(fun sound_touch_options_fold/2, {[], JObj}, Options),
    kz_binary:join(lists:reverse(Args), <<" ">>).

-type sound_touch_fun() :: fun((kz_json:json_term(), ne_binaries())-> ne_binaries()).
-type sound_touch_option() :: {ne_binary(), sound_touch_fun()}.
-type sound_touch_option_acc() :: {ne_binaries(), kz_json:object()}.

-spec sound_touch_options_fold(sound_touch_option(), sound_touch_option_acc()) -> sound_touch_option_acc().
sound_touch_options_fold({K, F}, {List, JObj}=Acc) ->
    case kz_json:get_ne_binary_value(K, JObj) of
        'undefined' -> Acc;
        V -> {F(V, List), JObj}
    end.
