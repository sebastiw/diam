-module(diam_watchdog).

-behaviour(gen_server).

-export([
    start_link/1,
    reset_watchdog_timer/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("diameter/include/diameter.hrl").
-include_lib("diam/include/diam.hrl").

-record(state, {
    status :: okay | suspect | down | reopen | initial,
    pending :: boolean(),
    tw :: integer(),
    tref :: undefined | reference(),
    num_dwa :: integer(),
    peer_pid :: pid(),
    socket :: pid()
}).

-define(TW_INIT, 30000).

start_link(Config) ->
    PeerName = maps:get(name, Config, ?MODULE),
    WdProc = get_wd_proc_name(PeerName),
    gen_server:start_link({local, WdProc}, ?MODULE, [Config], []).

reset_watchdog_timer(WdPid, Header) ->
    gen_server:cast(WdPid, {reset_wd, Header}).

%% gen_server implementations

init([Config]) ->
    TRef = timer:send_after(?TW_INIT, wd_timeout),
    State =
        #state{
            status = okay,
            pending = false,
            tw = ?TW_INIT,
            tref = TRef,
            num_dwa = 0,
            peer_pid = maps:get(peer_pid, Config),
            socket = maps:get(socket, Config)
        },
    {ok, State}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State, State#state.tw}.

handle_cast({reset_wd, ?DWA}, State) ->
    NewState = handle_dwa(State),
    {noreply, NewState#state{pending = false}};
handle_cast(_Msg, #state{status = Status} = State) when Status == okay orelse Status == suspect->
    TRef = reset_timer(State#state.tref, State#state.tw),
    {noreply, State#state{tref = TRef}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(wd_timeout, #state{status = okay, pending = true} = State) ->
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{status = suspect, tref = TRef}}; 
handle_info(wd_timeout, #state{status = okay} = State) ->
    send_dwr(State#state.peer_pid, State#state.socket),
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{tref = TRef, pending = true}}; 
handle_info(wd_timeout, #state{status = suspect} = State) ->
    %close_connection(),
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{status = down, tref = TRef}};
handle_info(wd_timeout, #state{status = Status} = State) when Status == initial orelse Status == down ->
    %attempt_open(),
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{tref = TRef}};
handle_info(wd_timeout, #state{status = reopen, pending = false} = State) ->
    send_dwr(State#state.peer_pid, State#state.socket),
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{pending = true, tref = TRef}};
handle_info(wd_timeout, #state{status = reopen} = State) ->
    case State#state.num_dwa < 0 of
        true ->
            Status = down,
            NumDwa = State#state.num_dwa;
            %close_connection();
        false ->
            Status = State#state.status,
            NumDwa = -1
    end,
    Jitter = calculate_jitter(),
    TRef = timer:send_after(State#state.tw + Jitter, wd_timeout),
    {noreply, State#state{tref = TRef, status = Status, num_dwa = NumDwa}};
handle_info(wd_timeout, State) ->
    {noreply, State};
handle_info(timeout, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

get_wd_proc_name(PeerName) ->
   Name = atom_to_list(PeerName) ++ "_wd",
   list_to_atom(Name).

handle_dwa(#state{status = okay} = State) ->
    TRef = reset_timer(State#state.tref, State#state.tw),
    State#state{tref = TRef};
handle_dwa(#state{status = suspect} = State) ->
    TRef = reset_timer(State#state.tref, State#state.tw),
    State#state{status = okay, tref = TRef};
handle_dwa(#state{status = reopen, num_dwa = 2} = State) ->
    State#state{status = okay, num_dwa = 0};
handle_dwa(#state{status = reopen, num_dwa = NumDwa} = State) ->
    State#state{num_dwa = NumDwa + 1};
handle_dwa(State) ->
    State.

reset_timer(TRef, Tw) ->
    timer:cancel(TRef),
    Jitter = calculate_jitter(),
    timer:send_after(Tw + Jitter, wd_timeout).

calculate_jitter() ->
    (rand:uniform(5) -3) * 1000.   

send_dwr(PeerPid, Socket) ->
    diam_peer:send_dwr_msg(PeerPid, Socket).
