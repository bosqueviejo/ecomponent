%%%-------------------------------------------------------------------
%%% File		: ecomponent.erl
%%% Author	: Jose Luis Navarro <pepe@yuilop.com>
%%% Description : ecomponent Service - External Component
%%% Provides:
%%%		
%%%
%%% Created : 07 Jun 2012 by Jose Luis Navarro <pepe@yuilop.com>
%%%-------------------------------------------------------------------

-module(ecomponent).
-behaviour(gen_server).

-include_lib("exmpp/include/exmpp.hrl").
-include_lib("exmpp/include/exmpp_client.hrl").
-include("../include/ecomponent.hrl").

-record(matching, {id, processor}).

%% API
-export([prepare_id/1, unprepare_id/1, is_allowed/2, send_packet/3, get_processor/1, get_processor_by_ns/2]).

%% gen_server callbacks
-export([start_link/0, init/8, init/1, handle_call/3, handle_cast/2, handle_info/2,
				 terminate/2, code_change/3]).

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(_) ->
	lager:info("Loading Application eComponent", []),
	mnesia:create_table(matching, [{attributes, record_info(fields, matching)}]),
	init(application:get_env(ecomponent, jid),
			 application:get_env(ecomponent, pass),
			 application:get_env(ecomponent, server),
			 application:get_env(ecomponent, port),
			 application:get_env(ecomponent, whitelist),
			 application:get_env(ecomponent, max_per_period),
			 application:get_env(ecomponent, period_seconds),
			 application:get_env(ecomponent, processors)).


init({_,JID}, {_,Pass}, {_,Server}, {_,Port}, {_,WhiteList}, {_,MaxPerPeriod}, {_,PeriodSeconds}, {_,Processors}) ->
	lager:info("JID ~p", [JID]),
	lager:info("Pass ~p", [Pass]),
	lager:info("Server ~p", [Server]),
	lager:info("Port ~p", [Port]),
	lager:info("WhiteList ~p", [WhiteList]),
	lager:info("MaxPerPeriod ~p", [MaxPerPeriod]),
	lager:info("PeriodSeconds ~p", [PeriodSeconds]),
	lager:info("Processors ~p", [Processors]),
	application:start(exmpp),
	mod_monitor:init(WhiteList),
	lager:info("mod_monitor started"),
	{_, XmppCom} = make_connection(JID, Pass, Server, Port),
	{ok, #state{xmppCom=XmppCom, jid=JID, pass=Pass, server=Server, port=Port, whiteList=WhiteList, maxPerPeriod=MaxPerPeriod, periodSeconds=PeriodSeconds, processors=Processors}};
init(_, _, _, _, _, _, _ , _) ->
lager:error("Some param is undefined"),
	{error, #state{}}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(#received_packet{packet_type=iq, type_attr=Type, raw_packet=IQ, from=From}, #state{maxPerPeriod=MaxPerPeriod, periodSeconds=PeriodSeconds}=State) ->
	case mod_monitor:accept(From, MaxPerPeriod, PeriodSeconds) of
		true ->
			spawn(iq_handler, pre_process_iq, [Type, IQ, From, State]),
			{noreply, State};
		_ ->
			{noreply, State}
	end;

handle_info({_, tcp_closed}, #state{jid=JID, server=Server, pass=Pass, port=Port}=State) ->
	lager:info("Connection Closed. Trying to Reconnect...~n", []),
	{_, NewXmppCom} = make_connection(JID, Pass, Server, Port),
	lager:info("Reconnected.~n", []),
	{noreply, State#state{xmppCom=NewXmppCom}};

handle_info({_,{bad_return_value, _}}, #state{jid=JID, server=Server, pass=Pass, port=Port}=State) ->
	lager:info("Connection Closed. Trying to Reconnect...~n", []),
	{_, NewXmppCom} = make_connection(JID, Pass, Server, Port),
	lager:info("Reconnected.~n", []),
	{noreply, State#state{xmppCom=NewXmppCom}};

handle_info(stop, #state{xmppCom=XmppCom}=State) ->
	lager:info("Component Stopped.~n",[]),
	exmpp_component:stop(XmppCom),
	{noreply, State};

handle_info(Record, State) -> 
	lager:info("Unknown Info Request: ~p~n", [Record]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
	lager:info("Received: ~p~n", [_Msg]), 
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(Info,_From, _State) ->
	lager:info("Received Call: ~p~n", [Info]),
	{reply, ok, _State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	lager:info("Terminating Component...", []),
	application:stop(exmpp),
	lager:info("Terminated Component.", []),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

send_packet(XmppCom, #iq{kind=request, id=ID}=Packet, Processor) ->
	save_id(ID, Processor),
	exmpp_component:send_packet(XmppCom, Packet);

send_packet(XmppCom, Packet, _) ->
	exmpp_component:send_packet(XmppCom, Packet).

save_id(Id, Processor) ->
	N = #matching{id=Id, processor=Processor},
	case mnesia:write({matching, N}) of
	{'EXIT', Reason} ->
		lager:error("Error writing id ~s, processor ~p on mnesia, reason: ~p", [Id, Processor, Reason]);
	_ -> N
	end.

get_processor(Id) ->
	V = mnesia:dirty_read(matching, Id),
	case V of
	{'EXIT', Reason} ->
		lager:error("Error getting processor with id ~s on mnesia, reason: ~p",[Id, Reason]),
		undefined; 
	[] -> 
		lager:warning("Found no processor for ~s",[Id]),
		undefined;
	[N|_] -> N#matching.processor
	end.

get_processor_by_ns(_, []) -> undefined;
get_processor_by_ns(Ns, Processors) ->
	lager:info("Search namespace ~s on ~p", [Ns, Processors]),
	proplists:get_value(Ns, Processors).

make_connection(JID, Pass, Server, Port) -> 
	XmppCom = exmpp_component:start(),
	make_connection(XmppCom, JID, Pass, Server, Port, 20).
make_connection(XmppCom, JID, Pass, Server, Port, 0) -> 
	exmpp_component:stop(XmppCom),
	make_connection(JID, Pass, Server, Port);
make_connection(XmppCom, JID, Pass, Server, Port, Tries) ->
	lager:info("Connecting: ~p Tries Left~n",[Tries]),
	exmpp_component:auth(XmppCom, JID, Pass),
	try exmpp_component:connect(XmppCom, Server, Port) of
		R -> exmpp_component:handshake(XmppCom),
		lager:info("Connected.~n",[]),
		{R, XmppCom}
	catch
		Exception -> lager:warning("Exception: ~p~n",[Exception]),	 %%TODO change for lager
		timer:sleep((20-Tries) * 200),
		make_connection(XmppCom, JID, Pass, Server, Port, Tries-1)
	end.

prepare_id([]) -> [];
prepare_id([$<|T]) -> [$x|prepare_id(T)];
prepare_id([$>|T]) -> [$X|prepare_id(T)];
prepare_id([H|T]) -> [H|prepare_id(T)].

unprepare_id([]) -> [];
unprepare_id([$x|T]) -> [$<|unprepare_id(T)];
unprepare_id([$X|T]) -> [$>|unprepare_id(T)];
unprepare_id([H|T]) -> [H|unprepare_id(T)].

is_allowed(_, []) -> true;
is_allowed({_,D,_}, WhiteDomain) ->
	is_allowed(D, WhiteDomain);
is_allowed(Domain, WhiteDomain) -> 
	lists:any(fun(S) -> S == Domain end, WhiteDomain).

