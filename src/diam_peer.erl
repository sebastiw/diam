-module(diam_peer).
-moduledoc """
Diameter Peer State Machine
""".

-behaviour(gen_statem).

-export([start_link/1,
         start_link/2,
         connect_init/2,
         connect_fail/3,
         receive_msg/4
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

start_link(Opts) when is_map(Opts) ->
  POpts = maps:get(peer_options, Opts, #{}),
  start_link(maps:get(name, POpts, ?MODULE), Opts).

start_link(PeerName, Opts) ->
  TProc = self(),
  gen_statem:start_link({local, PeerName}, ?MODULE, Opts#{transport_proc => TProc}, []).

connect_init(PProc, TRef) ->
  gen_statem:cast(PProc, {connect_init, TRef}).

connect_fail(PProc, TRef, Reason) ->
  gen_statem:cast(PProc, {connect_fail, TRef, Reason}).

receive_msg(PProc, TRef, Header, Bin) ->
  gen_statem:cast(PProc, {receive_msg, TRef, Header, Bin}).

%% ---------------------------------------------------------------------------
%% State machine
%% ---------------------------------------------------------------------------

callback_mode() ->
  [handle_event_function, state_enter].

init(AllOpts) ->
  Data = init_data(AllOpts),
  {ok, closed, Data}.

init_data(AllOpts) ->
  Opts = maps:get(peer_options, AllOpts),
  TProc = maps:get(transport_proc, AllOpts),
  TOpts = maps:get(transport_options, AllOpts),
  {ok, HostMP} = re:compile(maps:get(allowed_host_pattern, Opts, <<".*">>)),
  {ok, RealmMP} = re:compile(maps:get(allowed_realm_pattern, Opts, <<".*">>)),
  Mode = maps:get(mode, TOpts),
  LIPAddrs = maps:get(local_ip_addresses, TOpts, []),
  #{
    mode => Mode,
    allowed_host_pattern => HostMP,
    allowed_realm_pattern => RealmMP,
    local_host => maps:get(local_host, Opts),
    local_realm => maps:get(local_realm, Opts),
    local_ip_addresses => LIPAddrs,
    hbh => 0,
    e2e => 0,
    transport_proc => TProc
    }.

handle_event(enter, OldState, NewState, Data) ->
  Mode = maps:get(mode, Data),
  io:format("~p:~p:~p state change ~p->~p~n", [?MODULE, Mode, self(), OldState, NewState]),
  keep_state_and_data;

%% ----- closed -----
handle_event(_, {connect_init, TRef}, closed, #{mode := client} = Data) ->
  send_cer(TRef, Data),
  NewData = add_connecting_peer(Data, TRef),
  {next_state, wait_for_ce, NewData, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, {retry, TRef}}]};
handle_event(_, {connect_init, TRef}, closed, #{mode := server} = Data) ->
  NewData = add_connecting_peer(Data, TRef),
  {next_state, wait_for_ce, NewData};
handle_event(_, {connect_fail, TRef, _Reason}, closed, Data) ->
  %% Can we even get to this state?
  NewData = remove_peer(Data, TRef),
  {keep_state, NewData};

%% ----- wait_for_ce -----
handle_event(_, {receive_msg, TRef, ?CER, Bin}, wait_for_ce, #{mode := server} = Data) ->
  case test_cer(Data, Bin) of
    {true, CER} ->
      send_cea(TRef, Data, 2001),
      NewData = add_active_peer(Data, TRef, CER),
      {next_state, open, NewData, [{{timeout, capability_exchange}, cancel}]};
    {false, _} ->
      send_cea(TRef, Data, 3003),
      {keep_state_and_data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, {retry, TRef}}]}
  end;
handle_event(_, {receive_msg, TRef, ?CEA, Bin}, wait_for_ce, #{mode := client} = Data) ->
  case test_cea(Data, Bin) of
    {true, CEA} ->
      NewData = add_active_peer(Data, TRef, CEA),
      {next_state, open, NewData, [{{timeout, capability_exchange}, cancel}]};
    {_, CEA} ->
      io:format("~p:~p:~p nomatch ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, CEA]),
      {keep_state_and_data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, {retry, TRef}}]}
  end;
handle_event(_, {connect_init, TRef}, wait_for_ce, #{mode := client} = Data) ->
  send_cer(TRef, Data),
  NewData = add_connecting_peer(Data, TRef),
  {keep_state, NewData};
handle_event(_, {connect_init, TRef}, wait_for_ce, #{mode := server} = Data) ->
  NewData = add_connecting_peer(Data, TRef),
  {keep_state, NewData};

handle_event({timeout, capability_exchange}, {retry, TRef}, wait_for_ce, #{mode := server} = _Data) ->
  {keep_state_and_data, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, {retry, TRef}}]};
handle_event({timeout, capability_exchange}, {retry, TRef}, wait_for_ce, #{mode := client} = Data) ->
  %% Abort after X retries?
  send_cer(TRef, Data),
  NewData = add_connecting_peer(Data, TRef),
  {keep_state, NewData, [{{timeout, capability_exchange}, ?CAPABILITY_TIMER, {retry, TRef}}]};

%% ----- open -----
handle_event(_, {connect_fail, TRef, _Reason}, open, Data) ->
  NewData = remove_peer(Data, TRef),
  case {maps:get(active_peers, NewData, []), maps:get(connecting_peers, NewData, [])} of
    {[], []} ->
      {next_state, closed, NewData, []};
    {[], _} ->
      {next_state, wait_for_ce, NewData, []};
    {_, _} ->
      {keep_state, NewData}
  end;
handle_event(_, {connect_init, TRef}, open, #{mode := client} = Data) ->
  send_cer(TRef, Data),
  NewData = add_connecting_peer(Data, TRef),
  {keep_state, NewData};
handle_event(_, {connect_init, TRef}, open, #{mode := server} = Data) ->
  NewData = add_connecting_peer(Data, TRef),
  {keep_state, NewData};
handle_event(_, {receive_msg, TRef, ?CER, Bin}, open, #{mode := server} = Data) ->
  case test_cer(Data, Bin) of
    {true, CER} ->
      send_cea(TRef, Data, 2001),
      NewData = add_active_peer(Data, TRef, CER),
      {keep_state, NewData};
    {false, _} ->
      send_cea(TRef, Data, 3003),
      keep_state_and_data
  end;
handle_event(_, {receive_msg, TRef, ?CEA, Bin}, open, #{mode := client} = Data) ->
  case test_cea(Data, Bin) of
    {true, CEA} ->
      NewData = add_active_peer(Data, TRef, CEA),
      {keep_state, open, NewData};
    {_, CEA} ->
      io:format("~p:~p:~p nomatch ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, CEA]),
      keep_state_and_data
  end;
handle_event(_, Event, open, _Data) ->
  io:format("~p:~p:~p ~p~n", [?MODULE, open, ?LINE, Event]),
  keep_state_and_data.

terminate(_Why, _State, _Data) ->
  ok.

%% ---------------------------------------------------------------------------
%% Actions
%% ---------------------------------------------------------------------------

send_cer(TRef, Data) ->
  TProc = maps:get(transport_proc, Data),
  Host = maps:get(local_host, Data),
  Realm = maps:get(local_realm, Data),
  LocalIPs = maps:get(local_ip_addresses, Data),
  HBH = maps:get(hbh, Data),
  E2E = maps:get(e2e, Data),
  diam_sctp:send_msg(TProc, TRef, diam_msgs:cer(Host, Realm, HBH, E2E, LocalIPs)).

send_cea(TRef, Data, ResultCode) ->
  TProc = maps:get(transport_proc, Data),
  Host = maps:get(local_host, Data),
  Realm = maps:get(local_realm, Data),
  LocalIPs = maps:get(local_ip_addresses, Data),
  HBH = maps:get(hbh, Data),
  E2E = maps:get(e2e, Data),
  diam_sctp:send_msg(TProc, TRef, diam_msgs:cea(Host, Realm, HBH, E2E, LocalIPs, ResultCode)).

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

remove_peer(Data0, TRef) ->
  Data1 = maps:update_with(active_peers, fun (APs) -> lists:keydelete(TRef, 1, APs) end, [], Data0),
  maps:update_with(connecting_peers, fun (APs) -> APs -- [TRef] end, [], Data1).

add_active_peer(Data0, TRef, CE) ->
  Data1 = remove_peer(Data0, TRef),
  maps:update_with(active_peers, fun (APs) -> [{TRef, CE}|APs] end, [{TRef, CE}], Data1).

add_connecting_peer(Data, TRef) ->
  maps:update_with(connecting_peers, fun (APs) -> [TRef|APs] end, [TRef], Data).
