-module(diam_peer).
-moduledoc """
Diameter Peer State Machine
""".

-behaviour(gen_statem).

-export([start_link/0,
         start_link/1,
         start_link/2,
         connect_init/1,
         connect_fail/2,
         receive_msg/3
        ]).

-export([callback_mode/0,
         init/1,
         handle_event/4,
         terminate/3
        ]).

-include_lib("diameter/include/diameter.hrl").
-define(CER, #diameter_header{version = 1, application_id = 0, cmd_code = 257, is_request = true}).
-define(CEA, #diameter_header{version = 1, application_id = 0, cmd_code = 257, is_request = false}).

-define(CAPABILITY_TIMER, timer:seconds(5)).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

start_link() ->
  start_link(?MODULE).

start_link(Opts) when is_map(Opts) ->
  POpts = maps:get(peer_options, Opts, #{}),
  start_link(maps:get(name, POpts, ?MODULE), Opts);
start_link(PeerName) when is_atom(PeerName) ->
  Opts = #{
    peer_options => #{
      local_host => "my.domain.com",
      local_realm => "domain.com"
      }
    },
  start_link(PeerName, Opts).

start_link(PeerName, Opts) ->
  TProc = self(),
  gen_statem:start_link({local, PeerName}, ?MODULE, Opts#{transport_proc => TProc}, []).

connect_init(PProc) ->
  io:format("~p:~p:~p~n", [?MODULE, PProc, ?FUNCTION_NAME]),
  gen_statem:cast(PProc, connect_init).

connect_fail(PProc, Reason) ->
  io:format("~p:~p:~p (~p)~n", [?MODULE, PProc, ?FUNCTION_NAME, Reason]),
  gen_statem:cast(PProc, {connect_fail, Reason}).

receive_msg(PProc, Header, Bin) ->
  io:format("~p:~p:~p (~p)~n", [?MODULE, PProc, ?FUNCTION_NAME, Header]),
  gen_statem:cast(PProc, {receive_msg, Header, Bin}).

%% ---------------------------------------------------------------------------
%% State machine
%% ---------------------------------------------------------------------------

callback_mode() ->
  [handle_event_function, state_enter].

init(AllOpts) ->
  TPid = maps:get(transport_proc, AllOpts),
  Data = init_data(AllOpts, TPid),
  {ok, closed, Data}.

init_data(AllOpts, TPid) ->
  Opts = maps:get(peer_options, AllOpts),
  TOpts = maps:get(transport_options, AllOpts),
  {ok, HostMP} = re:compile(maps:get(allowed_host_pattern, Opts, <<".*">>)),
  {ok, RealmMP} = re:compile(maps:get(allowed_realm_pattern, Opts, <<".*">>)),
  Mode = maps:get(mode, TOpts),
  LIPAddrs = maps:get(local_ip_addresses, TOpts, []),
  #{
    mode => Mode,
    transport_proc => TPid,
    allowed_host_pattern => HostMP,
    allowed_realm_pattern => RealmMP,
    local_host => maps:get(local_host, Opts),
    local_realm => maps:get(local_realm, Opts),
    local_ip_addresses => LIPAddrs,
    hbh => 0,
    e2e => 0
    }.

handle_event(enter, OldState, NewState, Data) ->
  Mode = maps:get(mode, Data),
  io:format("~p:~p:~p state change ~p->~p~n", [?MODULE, Mode, self(), OldState, NewState]),
  keep_state_and_data;

%% ----- closed -----
handle_event(_, connect_init, closed, #{mode := client} = Data) ->
  send_cer(Data),
  {next_state, wait_for_cea, Data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, retry}]};
handle_event(_, connect_init, closed, #{mode := server} = Data) ->
  {next_state, wait_for_cer, Data};
handle_event(_, {connect_fail, _Reason}, closed, _Data) ->
  keep_state_and_data;

%% ----- wait_for_cer -----
handle_event(_, closed, wait_for_cer, Data) ->
  {next_state, closed, Data#{peer => undefined}, [{{timeout, capability_exchange}, cancel}]};
handle_event(_, {receive_msg, ?CER, Bin}, wait_for_cer, Data) ->
  case test_cer(Data, Bin) of
    {true, CER} ->
      send_cea(Data, 2001),
      NewData = Data#{peer => CER},
      {next_state, open, NewData};
    {false, _} ->
      send_cea(Data, 3003),
      {keep_state_and_data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, giveup}]}
  end;
handle_event({timeout, capability_exchange}, retry, wait_for_cer, Data) ->
  TProc = maps:get(transport_proc, Data),
  diam_sctp:stop(TProc);

%% ----- wait_for_cea -----
handle_event(_, closed, wait_for_cea, Data) ->
  {next_state, closed, Data#{peer => undefined}, [{{timeout, capability_exchange}, cancel}]};
handle_event(_, {receive_msg, ?CEA, Bin}, wait_for_cea, Data) ->
  case test_cea(Data, Bin) of
    {true, CEA} ->
      NewData = Data#{peer => CEA},
      {next_state, open, NewData, [{{timeout, capability_exchange}, cancel}]};
    {_, CEA} ->
      io:format("~p:~p:~p nomatch ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, CEA]),
      {keep_state_and_data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, retry}]}
  end;
handle_event({timeout, capability_exchange}, retry, wait_for_cea, Data) ->
  %% Abort after X retries?
  send_cer(Data),
  keep_state_and_data;

handle_event(_, {connect_fail, _Reason}, open, Data) ->
  {next_state, closed, Data#{peer => undefined}, []};
handle_event(_, _, open, _Data) ->
  keep_state_and_data.

terminate(_Why, _State, _Data) ->
  ok.

%% ---------------------------------------------------------------------------
%% Actions
%% ---------------------------------------------------------------------------

send_cer(Data) ->
  TProc = maps:get(transport_proc, Data),
  Host = maps:get(local_host, Data),
  Realm = maps:get(local_realm, Data),
  LocalIPs = maps:get(local_ip_addresses, Data),
  HBH = maps:get(hbh, Data),
  E2E = maps:get(e2e, Data),
  diam_sctp:send_msg(TProc, diam_msgs:cer(Host, Realm, HBH, E2E, LocalIPs)).

send_cea(Data, ResultCode) ->
  TProc = maps:get(transport_proc, Data),
  Host = maps:get(local_host, Data),
  Realm = maps:get(local_realm, Data),
  LocalIPs = maps:get(local_ip_addresses, Data),
  HBH = maps:get(hbh, Data),
  E2E = maps:get(e2e, Data),
  diam_sctp:send_msg(TProc, diam_msgs:cea(Host, Realm, HBH, E2E, LocalIPs, ResultCode)).

%% ---------------------------------------------------------------------------
%% Help functions
%% ---------------------------------------------------------------------------

test_cer(Data, Bin) ->
  CER = diam_msgs:decode(?CER, Bin),
  OHPat = maps:get(allowed_host_pattern, Data),
  ORPat = maps:get(allowed_realm_pattern, Data),
  [{true, OH}] = maps:get('Origin-Host', CER),
  [{true, OR}] = maps:get('Origin-Realm', CER),
  MOH = re:run(OH, OHPat, [{capture, none}]),
  MOR = re:run(OR, ORPat, [{capture, none}]),
  {match == MOH andalso match == MOR, CER}.

test_cea(Data, Bin) ->
  CEA = diam_msgs:decode(?CEA, Bin),
  OHPat = maps:get(allowed_host_pattern, Data),
  ORPat = maps:get(allowed_realm_pattern, Data),
  [{true, OH}] = maps:get('Origin-Host', CEA),
  [{true, OR}] = maps:get('Origin-Realm', CEA),
  MOH = re:run(OH, OHPat, [{capture, none}]),
  MOR = re:run(OR, ORPat, [{capture, none}]),
  [{true, <<ResultCode:32>>}] = maps:get('Result-Code', CEA),
  {2001 =:= ResultCode andalso match == MOH andalso match == MOR, CEA}.
