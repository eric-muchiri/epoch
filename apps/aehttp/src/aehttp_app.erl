%%%-------------------------------------------------------------------
%% @doc aehttp public API
%% @end
%%%-------------------------------------------------------------------

-module(aehttp_app).

-behaviour(application).


-define(DEFAULT_SWAGGER_EXTERNAL_PORT, 8043).
-define(DEFAULT_SWAGGER_EXTERNAL_LISTEN_ADDRESS, <<"0.0.0.0">>).
-define(DEFAULT_SWAGGER_INTERNAL_PORT, 8143).
-define(DEFAULT_SWAGGER_INTERNAL_LISTEN_ADDRESS, <<"127.0.0.1">>).

-define(DEFAULT_WEBSOCKET_INTERNAL_PORT, 8144).
-define(DEFAULT_WEBSOCKET_LISTEN_ADDRESS, <<"127.0.0.1">>).
-define(INT_ACCEPTORS_POOLSIZE, 100).

-define(DEFAULT_CHANNEL_WEBSOCKET_PORT, 8044).
-define(DEFAULT_CHANNEL_WEBSOCKET_LISTEN_ADDRESS, <<"127.0.0.1">>).
-define(CHANNEL_ACCEPTORS_POOLSIZE, 100).

%% Application callbacks
-export([start/2, stop/1]).

-export([check_env/0]).

%% Tests only
-export([ws_handlers_queue_max_size/0]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    {ok, Pid} = aehttp_sup:start_link(),
    {ok, _} = ws_task_worker_sup:start_link(),
    ok = start_http_api(),
    ok = start_websocket_internal(),
    ok = start_channel_websocket(),
    gproc:reg({n,l,{epoch, app, aehttp}}),
    {ok, Pid}.


%%--------------------------------------------------------------------
stop(_State) ->
    ok.


%%------------------------------------------------------------------------------
%% Check user-provided environment
%%------------------------------------------------------------------------------

check_env() ->
    %TODO: we need to validate that all tags are present
    GroupDefaults = #{<<"chain">>        => true,
                      <<"transaction">>  => true,
                      <<"account">>      => true,
                      <<"contract">>     => true,
                      <<"oracle">>       => true,
                      <<"name_service">> => true,
                      <<"channel">>      => true,
                      <<"node_info">>    => true,
                      <<"debug">>        => true,
                      <<"obsolete">>     => true
                      },
    EnabledGroups =
        lists:foldl(
            fun({Key, Default}, Accum) ->
                Enabled =
                    case aeu_env:user_config([<<"http">>, <<"endpoints">>, Key]) of
                        {ok, Setting} when is_boolean(Setting) ->
                            Setting;
                        undefined ->
                            Default
                    end,
                case Enabled of
                    true -> [Key | Accum];
                    false -> Accum
                end
            end,
            [],
            maps:to_list(GroupDefaults)),
        application:set_env(aehttp, enabled_endpoint_groups, EnabledGroups),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

start_http_api() ->
    ok = start_http_api(external, aehttp_dispatch_ext),
    ok = start_http_api(internal, aehttp_dispatch_int).

start_http_api(Target, LogicHandler) ->
    PoolSize = get_http_api_acceptors(Target),
    MaxConns = get_http_api_max_conns(Target),
    Port = get_http_api_port(Target),
    ListenAddress = get_http_api_listen_address(Target),

    Paths = aehttp_api_router:get_paths(Target, LogicHandler),
    Dispatch = cowboy_router:compile([{'_', Paths}]),

    Opts = [{port, Port},
            {ip, ListenAddress},
            {max_connections, MaxConns},
            {num_acceptors, PoolSize}],
    Env = #{env => #{dispatch => Dispatch},
            middlewares => [cowboy_router,
                            aehttp_cors_middleware,
                            cowboy_handler]},
    lager:debug("Target = ~p, Opts = ~p", [Target, Opts]),
    {ok, _} = cowboy:start_clear(Target, Opts, Env),
    ok.

start_websocket_internal() ->
    Port = get_internal_websockets_port(),
    Acceptors = get_internal_websockets_acceptors(),
    MaxConns = get_internal_websockets_max_conns(),
    ListenAddress = get_internal_websockets_listen_address(),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/websocket", ws_handler, []}
        ]}
    ]),
    Opts = [{port, Port},
            {ip, ListenAddress},
            {max_connections, MaxConns},
            {num_acceptors, Acceptors}],
    Env = #{env => #{dispatch => Dispatch}},
    lager:debug("Opts = ~p", [Opts]),
    {ok, _} = cowboy:start_clear(http, Opts, Env),
    ok.

start_channel_websocket() ->
    Port = get_channel_websockets_port(),
    Acceptors = get_channel_websockets_acceptors(),
    MaxConns = get_channel_websockets_max_conns(),
    ListenAddress = get_channel_websockets_listen_address(),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/channel", sc_ws_handler, []}
        ]}
    ]),
    Opts = [{port, Port},
            {ip, ListenAddress},
            {max_connections, MaxConns},
            {num_acceptors, Acceptors}],
    Env = #{env => #{dispatch => Dispatch}},
    lager:debug("Opts = ~p", [Opts]),
    {ok, _} = cowboy:start_clear(channels_socket, Opts, Env),
    ok.

get_and_parse_ip_address_from_config_or_env(CfgKey, App, EnvKey, Default) ->
    Config = aeu_env:user_config_or_env(CfgKey, App, EnvKey, Default),
    {ok, IpAddress} = inet:parse_address(binary_to_list(Config)),
    IpAddress.

get_http_api_acceptors(external) ->
    aeu_env:user_config_or_env([<<"http">>, <<"external">>, <<"acceptors">>],
                               aehttp, [external, acceptors], ?INT_ACCEPTORS_POOLSIZE div 10);
get_http_api_acceptors(internal) ->
    aeu_env:user_config_or_env([<<"http">>, <<"internal">>, <<"acceptors">>],
                               aehttp, [internal, acceptors], ?INT_ACCEPTORS_POOLSIZE div 10).

get_http_api_max_conns(external) ->
    aeu_env:user_config_or_env([<<"http">>, <<"external">>, <<"max_connections">>],
                               aehttp, [external, acceptors], ?INT_ACCEPTORS_POOLSIZE);
get_http_api_max_conns(internal) ->
    aeu_env:user_config_or_env([<<"http">>, <<"internal">>, <<"max_connections">>],
                               aehttp, [internal, acceptors], ?INT_ACCEPTORS_POOLSIZE).

get_http_api_port(external) ->
    aeu_env:user_config_or_env([<<"http">>, <<"external">>, <<"port">>],
                               aehttp, [external, port], ?DEFAULT_SWAGGER_EXTERNAL_PORT);
get_http_api_port(internal) ->
    aeu_env:user_config_or_env([<<"http">>, <<"internal">>, <<"port">>],
                               aehttp, [internal, port], ?DEFAULT_SWAGGER_INTERNAL_PORT).


get_http_api_listen_address(external) ->
    get_and_parse_ip_address_from_config_or_env([<<"http">>, <<"external">>, <<"listen_address">>],
                                                aehttp, [http, websocket, listen_address], ?DEFAULT_SWAGGER_EXTERNAL_LISTEN_ADDRESS);
get_http_api_listen_address(internal) ->
    get_and_parse_ip_address_from_config_or_env([<<"http">>, <<"internal">>, <<"listen_address">>],
                                                aehttp, [http, websocket, listen_address], ?DEFAULT_SWAGGER_INTERNAL_LISTEN_ADDRESS).

get_internal_websockets_listen_address() ->
    get_and_parse_ip_address_from_config_or_env([<<"websocket">>, <<"internal">>, <<"listen_address">>],
                                                aehttp, [internal, websocket, listen_address], ?DEFAULT_WEBSOCKET_LISTEN_ADDRESS).

get_internal_websockets_port() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"internal">>, <<"port">>],
                               aehttp, [internal, websocket, port], ?DEFAULT_WEBSOCKET_INTERNAL_PORT).

get_internal_websockets_acceptors() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"internal">>, <<"acceptors">>],
                               aehttp, [internal, websocket, handlers], ?INT_ACCEPTORS_POOLSIZE div 10).

get_internal_websockets_max_conns() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"internal">>, <<"max_connections">>],
                               aehttp, [internal, websocket, handlers], ?INT_ACCEPTORS_POOLSIZE).

ws_handlers_queue_max_size() -> 5.

get_channel_websockets_listen_address() ->
    get_and_parse_ip_address_from_config_or_env([<<"websocket">>, <<"channel">>, <<"listen_address">>],
                                                aehttp, [channel, websocket,
                                                         listen_address], ?DEFAULT_CHANNEL_WEBSOCKET_LISTEN_ADDRESS).

get_channel_websockets_port() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"channel">>, <<"port">>],
                               aehttp, [channel, websocket, port], ?DEFAULT_CHANNEL_WEBSOCKET_PORT).

get_channel_websockets_acceptors() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"channel">>, <<"acceptors">>],
                               aehttp, [channel, websocket, handlers], ?CHANNEL_ACCEPTORS_POOLSIZE div 10).

get_channel_websockets_max_conns() ->
    aeu_env:user_config_or_env([<<"websocket">>, <<"channel">>, <<"max_connections">>],
                               aehttp, [channel, websocket, handlers], ?CHANNEL_ACCEPTORS_POOLSIZE).

