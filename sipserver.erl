%%
%%--------------------------------------------------------------------

-module(sipserver).

%%-compile(export_all).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 start/2,
	 process/3,
	 get_env/1,
	 get_env/2,
	 make_logstr/2,
	 safe_spawn/2,
	 safe_spawn/3,
	 origin2str/2,
	 get_listenport/1,
	 get_all_listenports/0,
	 test/0
	]).

%%--------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------

-export([
	 safe_spawn_child/2,
	 safe_spawn_child/3
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("sipsocket.hrl").
-include("siprecords.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------

%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start(normal, [AppModule])
%%           AppModule = atom(), name of this Yxa application
%% Descrip.: The big start-function for the Yxa stack. Invoke this
%%           function to make the sun go up, and tell it the name of
%%           your Yxa application (AppModule) to have the stack invoke
%%           the correct init/0, request/3 and response/3 methods.
%% Returns : {ok, Sup}              |
%%           does not return at all
%%           Sup = pid of the Yxa OTP supervisor (module
%%                 sipserver_sup)
%%--------------------------------------------------------------------
start(normal, [AppModule]) ->
    catch ssl:start(),
    %% XXX uhm, is this sufficient? better than ssl:s internal seeding at least
    %% (since it uses a constant number)
    ssl:seed([sipserver:get_env(sipauth_password, ""), util:timestamp()]),
    mnesia:start(),
    [RemoteMnesiaTables, stateful, AppSupdata] = apply(AppModule, init, []),
    case sipserver_sup:start_link(AppModule) of
	{ok, Supervisor} ->
	    logger:log(debug, "starting, supervisor is ~p", [Supervisor]),
	    case siphost:myip() of
		"127.0.0.1" ->
		    logger:log(normal, "NOTICE: siphost:myip() returns 127.0.0.1, it is either "
			       "broken on your platform or you have no interfaces (except loopback) up");
		_ ->
		    true
	    end,
	    ok = init_mnesia(RemoteMnesiaTables),
	    {ok, Supervisor} = sipserver_sup:start_extras(Supervisor, AppSupdata),
	    {ok, Supervisor} = sipserver_sup:start_transportlayer(Supervisor),
	    logger:log(normal, "proxy started"),
	    {ok, Supervisor};
	Unknown ->
	    E = lists:flatten(io_lib:format("Failed starting supervisor : ~p", [Unknown])),
	    {error, E}
    end.

%%--------------------------------------------------------------------
%% Function: init_mnesia(RemoteTables)
%%           RemoteTables = list() of atom(), names of remote Mnesia
%%                          tables needed by this Yxa application.
%% Descrip.: Initiate Mnesia on this node. If there are no remote
%%           mnesia-tables, we conclude that we are a mnesia master
%%           and check if any of the tables needs to be updated.
%% Returns : ok | does not return at all
%%--------------------------------------------------------------------
init_mnesia(none) ->
    %% update old database versions
    ok = table_update:update(),
    ok;
init_mnesia(RemoteTables) when is_list(RemoteTables) ->
    DbNodes = case sipserver:get_env(databaseservers, none) of
		  none ->
		      logger:log(error, "Startup: This application needs remote tables ~p but you " ++
				 "haven't configured any databaseservers, exiting.",
				 [RemoteTables]),
		      logger:quit(none),
		      erlang:fault("No databaseservers configured");
		  Res ->
		      Res
	      end,
    logger:log(debug, "Mnesia extra db nodes : ~p", [DbNodes]),
    case mnesia:change_config(extra_db_nodes,
			      sipserver:get_env(databaseservers)) of
	{error, Reason} ->
	    logger:log(error, "Startup: Could not add configured databaseservers: ~p",
		       [mnesia:error_description(Reason)]),
	    logger:quit(none),
	    erlang:fault("Could not add configured databaseservers");
	_ ->
	    true
    end,
    find_remote_mnesia_tables(RemoteTables).

%%--------------------------------------------------------------------
%% Function: find_remote_mnesia_tables(RemoteTables)
%%           RemoteTables = list() of atom(), names of remote Mnesia
%%                          tables needed by this Yxa application.
%% Descrip.: Do mnesia:wait_for_tables() for RemoteTables, with a
%%           timeout since we (Stockholm university) have had
%%           intermittent problems with mnesia startups. Try a mnesia
%%           stop/start after 30 seconds, and stop trying by using
%%           erlang:fault() after another 30 seconds.
%% Returns : ok | does not return at all
%%
%% XXX are the problems asociated with the somewhat random startup
%% order of the nodes/applications? mnesia:start() is asynchronous
%% or is it the usage of ctrl-c to terminate node when debugging
%% which mnesia might perceive as a network error? - hsten
%%--------------------------------------------------------------------
find_remote_mnesia_tables(RemoteTables) ->
    logger:log(debug, "Initializing remote Mnesia tables ~p", [RemoteTables]),
    find_remote_mnesia_tables1(RemoteTables, RemoteTables, 0).

find_remote_mnesia_tables1(OrigTableList, RemoteTables, Count) ->
    case mnesia:wait_for_tables(RemoteTables, 10000) of
	ok ->
	    ok;
	{timeout, BadTabList} ->
	    case Count of
		3 ->
		    logger:log(normal, "Attempting a Mnesia restart because I'm still waiting for tables ~p",
			       [BadTabList]),
		    StopRes = mnesia:stop(),
		    StartRes = mnesia:start(),
		    logger:log(debug, "Mnesia stop() -> ~p, start() -> ~p", [StopRes, StartRes]),
		    find_remote_mnesia_tables1(OrigTableList, OrigTableList, Count + 1);
		6 ->
		    logger:log(error, "Could not initiate remote Mnesia tables ~p, exiting.", [BadTabList]),
		    logger:quit(none),
		    erlang:fault("Mnesia table init error", RemoteTables);
		_ ->
		    logger:log(debug, "Still waiting for tables ~p", [BadTabList]),
		    find_remote_mnesia_tables1(OrigTableList, BadTabList, Count + 1)
	    end
    end.

%%--------------------------------------------------------------------
%% Function: safe_spawn(Module, Fun)
%%           safe_spawn(Module, Function, Arguments)
%%           Fun = fun() | {Module, Function}
%%           Module, Function = atom() - names of module and function
%%           Arguments = list(), arguments for Function and
%%           Module:Function
%% Descrip.: run Function or Module:Function with Arguments as
%%           arguments, in a separate thread. Return true if no
%%           exception occured.
%% Returns : true  |
%%           error
%%--------------------------------------------------------------------
safe_spawn(Function, Arguments) ->
    spawn(?MODULE, safe_spawn_child, [Function, Arguments]).

safe_spawn(Module, Function, Arguments) ->
    spawn(?MODULE, safe_spawn_child, [Module, Function, Arguments]).


%%
safe_spawn_child(Function, Arguments) ->
    case catch apply(Function, Arguments) of
	{'EXIT', E} ->
	    logger:log(error, "=ERROR REPORT==== from ~p :~n~p", [Function, E]),
	    error;
	{siperror, Status, Reason} ->
	    logger:log(error, "Spawned function ~p generated a SIP-error (ignoring) : ~p ~s",
		       [Function, Status, Reason]),
	    error;
	{siperror, Status, Reason, _} ->
	    logger:log(error, "Spawned function ~p generated a SIP-error (ignoring) : ~p ~s",
		       [Function, Status, Reason]),
	    error;
	_ ->
	    true
    end.

%%
safe_spawn_child(Module, Function, Arguments) ->
    case catch apply(Module, Function, Arguments) of
	{'EXIT', E} ->
	    logger:log(error, "=ERROR REPORT==== from ~p:~p :~n~p", [Module, Function, E]),
	    error;
	{siperror, Status, Reason} ->
	    logger:log(error, "Spawned function ~p:~p generated a SIP-error (ignoring) : ~p ~s",
		       [Module, Function, Status, Reason]),
	    error;
	{siperror, Status, Reason, _} ->
	    logger:log(error, "Spawned function ~p:~p generated a SIP-error (ignoring) : ~p ~s",
		       [Module, Function, Status, Reason]),
	    error;
	_ ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: my_send_result(Request, Socket, Status, Reason,
%%                          ExtraHeaders)
%%           Request = request record()
%%           Socket  = sipsocket record()
%%           Status  = integer(), SIP response code
%%           Reason  = string(), error description
%%           ExtraHeaders = keylist record()
%% Descrip.: In sipserver we do lots of checking in the dark areas of
%%           transport layer, transaction layer or somewhere in
%%           between. When we detect unparseable requests for example,
%%           we generate an error response in sipserver but special
%%           care must be taken so that we do not generate responses
%%           to malformed ACK's. This function checks that.
%% Returns : ok  |
%%           Res
%%           Res = term(), result of transportlayer:send_result()
%%--------------------------------------------------------------------
my_send_result(Request, Socket, Status, Reason, ExtraHeaders) when record(Request, request) ->
    case Request#request.method of
	"ACK" ->
	    %% Empirical evidence says that it is a really bad idea to send responses to ACK
	    %% (since the response may trigger yet another ACK). Although not very clearly,
	    %% RFC3261 section 17 (Transactions) do say that responses to ACK is not permitted :
	    %% ' The client transaction is also responsible for receiving responses
	    %%   and delivering them to the TU, filtering out any response
	    %%   retransmissions or disallowed responses (such as a response to ACK).'
	    logger:log(normal, "Sipserver: Suppressing application error response ~p ~s in response to ACK ~s",
		       [Status, Reason, sipurl:print(Request#request.uri)]);
	_ ->
	    case transactionlayer:send_response_request(Request, Status, Reason, ExtraHeaders) of
		ok -> ok;
		_ ->
		    logger:log(error, "Sipserver: Failed sending caught error ~p ~s (in response to ~s ~s) " ++
			       "using transaction layer - sending directly on the socket we received the request on",
			       [Status, Reason, Request#request.method, sipurl:print(Request#request.uri)]),
		    transportlayer:send_result(Request#request.header, Socket, "", Status, Reason, ExtraHeaders)
	    end
    end.

%%--------------------------------------------------------------------
%% Function: internal_error(Request, Socket)
%%           Request = request record()
%%           Socket  = sipsocket record()
%% Descrip.: Send a 500 Server Internal Error, or some other given
%%           error, in response to a request (Request) received on a
%%           specific socket (Socket).
%% Returns : ok  |
%%           Res
%%           Res = term(), result of transportlayer:send_result()
%%--------------------------------------------------------------------
internal_error(Request, Socket) when record(Request, request), record(Socket, sipsocket) ->
    my_send_result(Request, Socket, 500, "Server Internal Error", []).

internal_error(Request, Socket, Status, Reason) when record(Request, request), record(Socket, sipsocket) ->
    my_send_result(Request, Socket, Status, Reason, []).

internal_error(Request, Socket, Status, Reason, ExtraHeaders) when record(Request, request),
								   record(Socket, sipsocket) ->
    my_send_result(Request, Socket, Status, Reason, ExtraHeaders).

%%--------------------------------------------------------------------
%% Function: process(Packet, Origin, Dst)
%%           Packet = string()
%%           Origin = siporigin record()
%%           Dst = transport_layer | Module
%% Descrip.: Check if something we received from a socket (Packet) is
%%           a valid SIP request/response by calling parse_packet() on
%%           it. Then, use my_apply to either send it on to the
%%           transaction layer, or invoke a modules request/3 or
%%           response/3 function on it - depending on the contents of
%%           Dst.
%% Returns : void(), does not matter.
%%--------------------------------------------------------------------
process(Packet, Origin, Dst) when record(Origin, siporigin) ->
    SipSocket = Origin#siporigin.sipsocket,
    case parse_packet(Packet, Origin) of
	{Request, LogStr} when record(Request, request) ->
	    case catch my_apply(Dst, Request, Origin, LogStr) of
		{'EXIT', E} ->
		    logger:log(error, "=ERROR REPORT==== from SIP message handler/transaction layer ~n~p", [E]),
		    internal_error(Request, SipSocket);
		{siperror, Status, Reason} ->
		    logger:log(error, "FAILED processing request: ~s -> ~p ~s", [LogStr, Status, Reason]),
		    internal_error(Request, SipSocket, Status, Reason);
		{siperror, Status, Reason, ExtraHeaders} ->
		    logger:log(error, "FAILED processing request: ~s -> ~p ~s", [LogStr, Status, Reason]),
		    internal_error(Request, SipSocket, Status, Reason, ExtraHeaders);
		_ ->
		    true
	    end;
	{Response, LogStr} when record(Response, response) ->
	    my_apply(Dst, Response, Origin, LogStr);
	_ ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: my_apply(Dst, Request, Origin, LogStr)
%%           Dst = transaction_layer | Module, Module is the name of a
%%                 module that exports a request/3 and a response/3
%%                 function
%%           Request = request record()
%%           Origin  = siporigin record()
%%           LogStr  = string(), textual description of request
%% Descrip.: If Dst is transaction_layer, gen_server call the
%%           transaction layer and let it decide our next action. If
%%           Dst is the name of a module, apply() that modules
%%           request/3 function.
%% Returns : true        |
%%           SIPerror    |
%%           ApplyResult
%%           SIPerror = {siperror, Status, Reason}
%%             Status = integer()
%%             Reason = string()
%%           ApplyResult = result of apply()
%%--------------------------------------------------------------------
my_apply(transaction_layer, R, Origin, LogStr) when record(R, request);
						    record(R, response), record(Origin, siporigin) ->
    %% Dst is the transaction layer.
    case transactionlayer:from_transportlayer(R, Origin, LogStr) of
	{continue} ->
	    %% terminate silently
	    true;
	{pass_to_core, AppModule} ->
	    %% Dst (the transaction layer presumably) wants us to apply a function with this
	    %% request/response as argument. This is common when the transaction layer has started
	    %% a new server transaction for this request and wants it passed to the core (or TU)
	    %% but can't do it itself because that would block the transactionlayer process.
	    my_apply(AppModule, R, Origin, LogStr);
	_ ->
	    Type = element(1, R),	%% get record type - 'request' or 'response'
	    logger:log(error, "Sipserver: Got no or unknown response from transaction_layer regarding ~p : ~s",
		       [Type, LogStr]),
	    {siperror, 500, "Server Internal Error"}
    end;
my_apply(AppModule, Request, Origin, LogStr) when atom(AppModule), record(Request, request),
						  record(Origin, siporigin) ->
    apply(AppModule, request, [Request, Origin, LogStr]);
my_apply(AppModule, Response, Origin, LogStr) when atom(AppModule), record(Response, response),
						   record(Origin, siporigin) ->
    apply(AppModule, response, [Response, Origin, LogStr]).

%%--------------------------------------------------------------------
%% Function: parse_packet(Packet, Origin)
%%           Packet = string()
%%           Origin = siporigin record()
%% Descrip.: Check if something we received from a socket (Packet) is
%%           a valid SIP request/response
%% Returns : {Msg, LogStr}          |
%%           void(), unspecified
%%           Msg = request record() |
%%                 response record()
%%           LogStr = string(), textua description of request/response
%%--------------------------------------------------------------------
parse_packet(Packet, Origin) when record(Origin, siporigin) ->
    Socket = Origin#siporigin.sipsocket,
    case catch sippacket:parse(Packet, Origin) of
	{'EXIT', E} ->
	    logger:log(error, "=ERROR REPORT==== from sippacket:parse()~n~p", [E]),
	    logger:log(error, "CRASHED parsing packet [client=~s]", [origin2str(Origin, "unknown")]),
	    false;
	{siperror, Status, Reason} ->
	    logger:log(error, "INVALID packet [client=~s] -> '~p ~s', CAN'T SEND RESPONSE",
		       [origin2str(Origin, "unknown"), Status, Reason]),
	    false;
	{siperror, Status, Reason, _ExtraHeaders} ->
	    logger:log(error, "INVALID packet [client=~s] -> '~p ~s', CAN'T SEND RESPONSE",
		       [origin2str(Origin, "unknown"), Status, Reason]),
	    false;
	keepalive ->
	    true;
	Parsed ->
	    %% From here on, we can generate responses to the UAC on error
	    case catch process_parsed_packet(Parsed, Origin) of
		{'EXIT', E} ->
		    logger:log(error, "=ERROR REPORT==== from sipserver:process_parsed_packet() :~n~p", [E]),
		    {error};
		{sipparseerror, request, Header, Status, Reason} ->
		    logger:log(error, "INVALID request [client=~s] ~p ~s",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    parse_do_internal_error(Header, Socket, Status, Reason, []);
		{sipparseerror, request, Header, Status, Reason, ExtraHeaders} ->
		    logger:log(error, "INVALID request [client=~s]: ~s -> ~p ~s",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    parse_do_internal_error(Header, Socket, Status, Reason, ExtraHeaders);
		{sipparseerror, response, _Header, Status, Reason} ->
		    logger:log(error, "INVALID response [client=~s] -> '~p ~s' (dropping)",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    false;
		{sipparseerror, response, _Header, Status, Reason, _ExtraHeaders} ->
		    logger:log(error, "INVALID response [client=~s] -> '~p ~s' (dropping)",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    false;
		{siperror, Status, Reason} ->
		    logger:log(error, "INVALID packet [client=~s] -> '~p ~s', CAN'T SEND RESPONSE",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    false;
		{siperror, Status, Reason, _ExtraHeaders} ->
		    logger:log(error, "INVALID packet [client=~s] -> '~p ~s', CAN'T SEND RESPONSE",
			       [origin2str(Origin, "unknown"), Status, Reason]),
		    false;
		Res ->
		    Res
	    end
    end.

%%--------------------------------------------------------------------
%% Function: parse_do_internal_error(Header, Socket, Status, Reason,
%%                                   ExtraHeaders)
%%           Header = term(), opaque (keylist record())
%%           Socket = term(), opaque (sipsocket record())
%%           Status = integer(), SIP status code
%%           Reason = string(), SIP reason phrase
%%           ExtraHeaders = term(), opaque (keylist record())
%% Descrip.: Handle errors returned during initial parsing of a
%%           request. These errors occur before the transaction layer
%%           is notified of the requests, so there are never any
%%           server transactions to handle the errors. Just send them.
%% Returns : ok
%%--------------------------------------------------------------------
parse_do_internal_error(Header, Socket, Status, Reason, ExtraHeaders) ->
    {_, Method} = sipheader:cseq(Header),
    case Method of
	"ACK" ->
	    %% Empirical evidence says that it is a really bad idea to send responses to ACK
	    %% (since the response may trigger yet another ACK). Although not very clearly,
	    %% RFC3261 section 17 (Transactions) do say that responses to ACK is not permitted :
	    %% ' The client transaction is also responsible for receiving responses
	    %%   and delivering them to the TU, filtering out any response
	    %%   retransmissions or disallowed responses (such as a response to ACK).'
	    logger:log(normal, "Sipserver: Suppressing parsing error response ~p ~s because CSeq method is ACK",
		       [Status, Reason]);
	_ ->
	    transportlayer:send_result(Header, Socket, "", Status, Reason, ExtraHeaders)
    end,
    ok.

%%--------------------------------------------------------------------
%% Function: process_parsed_packet(Request, Origin)
%%           Request = request record()
%%           Origin  = siporigin record(), information about where
%%                     this Packet was received from
%% Descrip.: Do alot of transport/transaction layer checking/work on
%%           a request or response we have received and previously
%%           concluded was parseable. For example, do RFC3581 handling
%%           of rport parameter on top via, check for loops, check if
%%           we received a request from a strict router etc.
%% Returns : {NewRequest, LogStr}
%%--------------------------------------------------------------------
process_parsed_packet(Request, Origin) when record(Request, request), record(Origin, siporigin) ->
    NewHeader1 = fix_topvia_received(Request#request.header, Origin),
    NewHeader2 = fix_topvia_rport(NewHeader1, Origin),
    check_packet(Request#request{header=NewHeader2}, Origin),
    {NewURI, NewHeader3} =
	case received_from_strict_router(Request#request.uri, NewHeader2) of
	    true ->
		logger:log(debug, "Sipserver: Received request with a"
			   " Request-URI I (probably) put in a Record-Route. "
			   "Pop real Request-URI from Route-header."),
		ReverseRoute = lists:reverse(sipheader:route(NewHeader2)),
		[FirstRoute | NewReverseRoute] = ReverseRoute,
		NewReqURI = sipurl:parse(FirstRoute#contact.urlstr),
		NewH =
		    case NewReverseRoute of
			[] ->
			    keylist:delete("Route", NewHeader2);
			_ ->
			    keylist:set("Route", sipheader:contact_print(
						   lists:reverse(NewReverseRoute)), NewHeader2)
		end,
		{NewReqURI, NewH};
	    _ ->
		{Request#request.uri, NewHeader2}
	end,
    NewHeader4 = remove_route_matching_me(NewHeader3),
    NewRequest = Request#request{uri=NewURI, header=NewHeader4},
    LogStr = make_logstr(NewRequest, Origin),
    {NewRequest, LogStr};

%%--------------------------------------------------------------------
%% Function: process_parsed_packet(Response, Origin)
%%           Response = response record()
%%           Origin   = siporigin record(), information about where
%%                      this Packet was received from
%% Descrip.: Do alot of transport/transaction layer checking/work on
%%           a request or response we have received and previously
%%           concluded was parseable. For example, do RFC3581 handling
%%           of rport parameter on top via, check for loops, check if
%%           we received a request from a strict router etc.
%% Returns : {NewResponse, LogStr} |
%%           {invalid}
%%--------------------------------------------------------------------
process_parsed_packet(Response, Origin) when is_record(Response, response), is_record(Origin, siporigin) ->
    check_packet(Response, Origin),
    TopVia = sipheader:topvia(Response#response.header),
    case check_response_via(Origin, TopVia) of
	ok ->
	    LogStr = make_logstr(Response, Origin),
	    {Response, LogStr};
	error ->
	    %% Silently drop packet
	    {invalid}
    end.

%%--------------------------------------------------------------------
%% Function: check_response_via(Origin, TopVia)
%%           Origin   = siporigin record(), information about where
%%                      this Packet was received from
%%           TopVia   = via record() | none
%% Descrip.: Check that there actually was a Via header in this
%%           response, and check if it matches us.
%% Returns : ok    |
%%           error
%%--------------------------------------------------------------------
check_response_via(Origin, none) ->
    logger:log(error, "INVALID top-Via in response [client=~s] (no Via found).",
	       [origin2str(Origin, "unknown")]),
    error;
check_response_via(Origin, TopVia) when is_record(TopVia, via) ->
    %% Check that top-Via is ours (RFC 3261 18.1.2),
    %% silently drop message if it is not.

    %% Create a Via that looks like the one we would have produced if we sent the request
    %% this is an answer to, but don't include parameters since they might have changed
    Proto = Origin#siporigin.proto,
    %% This is what we expect, considering the protocol in Origin (Proto)
    MyViaNoParam = siprequest:create_via(Proto, []),
    %% But we also accept this, which is the same but with the protocol from this response - in
    %% case we sent the request out using TCP but received the response over UDP for example
    SentByMeNoParam = siprequest:create_via(sipsocket:viaproto2proto(TopVia#via.proto), []),
    case sipheader:via_is_equal(TopVia, MyViaNoParam, [proto, host, port]) of
        true ->
	    ok;
	false ->
	    case sipheader:via_is_equal(TopVia, SentByMeNoParam, [proto, host, port]) of
		true ->
		    %% This can happen if we for example send a request out on a TCP socket, but the
		    %% other end responds over UDP.
		    logger:log(debug, "Sipserver: Warning: received response [client=~s]"
			       " matching me, but different protocol ~p (received on: ~p)",
			       [origin2str(Origin, "unknown"),
				TopVia#via.proto, sipsocket:proto2viastr(Origin#siporigin.proto)]),
		    ok;
		false ->
		    logger:log(error, "INVALID top-Via in response [client=~s]."
			       " Top-Via (without parameters) (~s) does not match mine (~s). Discarding.",
			       [origin2str(Origin, "unknown"), sipheader:via_print([TopVia#via{param=[]}]),
				sipheader:via_print([MyViaNoParam])]),
		    error
	    end
    end.

%%--------------------------------------------------------------------
%% Function: fix_topvia_received(Header, Origin)
%%           Header = term(), opaque (keylist record())
%%           Origin = siporigin record()
%% Descrip.: Add received= parameter to top Via of a requests Header
%%           if we need to. RFC 3261 #18.2.1.
%% Returns : NewHeader
%%           NewHeader = term(), opaque (a new keylist record())
%%--------------------------------------------------------------------
fix_topvia_received(Header, Origin) when record(Origin, siporigin) ->
    IP = Origin#siporigin.addr,
    %% Check "sent-by" in top-Via to see if we MUST add a
    %% received= parameter (RFC 3261 18.2.1)
    TopVia = sipheader:topvia(Header),
    case TopVia#via.host of
	IP ->
	    Header;
	_ ->
	    ParamDict = sipheader:param_to_dict(TopVia#via.param),
	    NewDict = dict:store("received", IP, ParamDict),
	    NewVia = TopVia#via{param=sipheader:dict_to_param(NewDict)},
	    logger:log(debug, "Sipserver: TopViaHost ~p does not match IP ~p, appending received=~s parameter",
		       [TopVia#via.host, IP, IP]),
	    replace_top_via(NewVia, Header)
    end.

%%--------------------------------------------------------------------
%% Function: fix_topvia_rport(Header, Origin)
%%           Header = term(), opaque (keylist record())
%%           Origin = siporigin record()
%% Descrip.: Implement handling of rport= top Via parameter upon
%%           receiving a request with an 'rport' parameter. RFC3581.
%% Returns : NewHeader
%%           NewHeader = term(), opaque (a new keylist record())
%%--------------------------------------------------------------------
%% XXX this RFC3581 implementation is not 100% finished. RFC3581 Section 4 says we MUST
%% send the responses to this request back from the same IP and port we received the
%% request to. We should be able to solve this when sending responses if we keep a list
%% of requests and sockets even for requests received over UDP too. XXX make it so.
fix_topvia_rport(Header, Origin) when record(Origin, siporigin) ->
    IP = Origin#siporigin.addr,
    Port = Origin#siporigin.port,
    PortStr = integer_to_list(Port),
    TopVia = sipheader:topvia(Header),
    ParamDict = sipheader:param_to_dict(TopVia#via.param),
    case dict:find("rport", ParamDict) of
	error ->
	    Header;
	{ok, []} ->
	    logger:log(debug, "Sipserver: Client requests symmetric response routing, setting rport=~p", [Port]),
	    NewDict1 = dict:store("rport", PortStr, ParamDict),
	    %% RFC3581 Section 4 says we MUST add a received= parameter when client
	    %% requests rport even if the sent-by is set to the IP-address we received
	    %% the request from.
	    NewDict = dict:store("received", IP, NewDict1),
	    NewVia = TopVia#via{param=sipheader:dict_to_param(NewDict)},
	    replace_top_via(NewVia, Header);
	{ok, PortStr} ->
	    logger:log(debug, "Sipserver: Top Via has rport already set to ~p,"
		       " remote party isn't very RFC3581 compliant.",
		       [Port]),
	    Header;
	{ok, RPort} ->
	    logger:log(error, "Sipserver: Received request with rport already"
		       " containing a value (~p)! Overriding with port ~p.",
		       [RPort, Port]),
	    NewDict = dict:store("rport", PortStr, ParamDict),
	    NewVia = TopVia#via{param=sipheader:dict_to_param(NewDict)},
	    replace_top_via(NewVia, Header)
    end.

%% Replace top Via header in a keylist record()
replace_top_via(NewVia, Header) when record(NewVia, via) ->
    [_FirstVia | Via] = sipheader:via(Header),
    keylist:set("Via", sipheader:via_print(lists:append([NewVia], Via)), Header).

%%--------------------------------------------------------------------
%% Function: received_from_strict_router(URI, Header)
%%           URI = sipurl record()
%%           Header = term(), opaque (keylist record())
%% Descrip.: Look at the URI of a request we just received to see
%%           if it is something we (possibly) put in a Record-Route
%%           and this is a request sent from a strict router
%%           (RFC2543 compliant UA).
%% Returns: true |
%%          false
%%--------------------------------------------------------------------
received_from_strict_router(URI, Header) when record(URI, sipurl) ->
    MyPorts = sipserver:get_all_listenports(),
    MyIP = siphost:myip(),
    HostnameList = lists:append(sipserver:get_env(myhostnames, []), siphost:myip_list()),
    %% If the URI has a username in it, it is not something we've put in a Record-Route
    UsernamePresent = case URI#sipurl.user of
			  none -> false;
			  T when list(T) -> true
		      end,
    HostnameIsMyHostname = util:casegrep(URI#sipurl.host, HostnameList),
    %% In theory, we should not treat an absent port number in this Request-URI as
    %% if the default port number was specified in there, but in practice that is
    %% what we have to do since some UAs can remove the port we put into the
    %% Record-Route
    Port = siprequest:default_port(URI#sipurl.proto, sipurl:get_port(URI)),
    PortMatches = lists:member(Port, MyPorts),
    MAddrMatch = case dict:find("maddr", sipheader:param_to_dict(URI#sipurl.param)) of
		     {ok, MyIP} -> true;
		     {ok, _OtherIP} ->
			 false;
		     _ ->
			 %% this should really return 'false', but some SIP-stacks
			 %% evidently strip parameters so we treat the absence of maddr
			 %% parameter as if it matches
			 true
		 end,
    HeaderHasRoute = case keylist:fetch('route', Header) of
			 [] -> false;
			 _ -> true
		     end,
    if
	UsernamePresent /= false -> false;
	HostnameIsMyHostname /= true -> false;
	PortMatches /= true -> false;
	MAddrMatch /= true -> false;
	HeaderHasRoute /= true ->
	    logger:log(debug, "Sipserver: Warning: Request-URI looks like something"
		       " I put in a Record-Route header, but request has no Route!"),
	    false;
	true -> true
    end.

%%--------------------------------------------------------------------
%% Function: remove_route_matching_me(Header)
%%           Header = term(), opaque (keylist record())
%% Descrip.: Look at the first Route header element in Header (if any)
%%           and see if it matches this proxy. If so, remove the first
%%           element and return a new Header.
%% Returns : NewHeader
%%           NewHeader = term(), opaque (new keylist record(), or the
%%                       same as input if no changes were made)
%%--------------------------------------------------------------------
remove_route_matching_me(Header) ->
    Route = sipheader:route(Header),
    case Route of
        [#contact{urlstr = FirstRoute} | NewRoute] ->
	    case route_matches_me(sipurl:parse(FirstRoute)) of
		true ->
		    logger:log(debug, "Sipserver: First Route ~p matches me, removing it.",
			       [ contact:print(contact:new(none, FirstRoute, [])) ]),
		    NewHeader =
			case NewRoute of
			    [] ->
				keylist:delete("Route", Header);
			    _ ->
				keylist:set("Route", sipheader:contact_print(NewRoute), Header)
			end,
		    NewHeader;
		_ ->
		    Header
	    end;
	_ ->
	    Header
    end.

%%--------------------------------------------------------------------
%% Function: route_matches_me(Route)
%%           Route = sipurl record()
%% Descrip.: Helper function for remove_route_matching_me/1. Check if
%%           an URL matches this proxys name (or address) and port.
%% Returns : true  |
%%           false
%%--------------------------------------------------------------------
route_matches_me(Route) when is_record(Route, sipurl) ->
    MyPorts = sipserver:get_all_listenports(),
    Port = siprequest:default_port(Route#sipurl.proto, sipurl:get_port(Route)),
    PortMatches = lists:member(Port, MyPorts),
    HostnameList = lists:append(get_env(myhostnames, []), siphost:myip_list()),
    HostnameMatches = util:casegrep(Route#sipurl.host, HostnameList),
    if
	HostnameMatches /= true -> false;
	PortMatches /= true -> false;
	true ->	true
    end.

%%--------------------------------------------------------------------
%% Function: check_packet(Packet, Origin)
%%           Packet  = request record() | response record()
%%           Origin  = siporigin record(), information about where
%%                     this Packet was received from
%% Descrip.: Sanity check To: and From: in a received request/response
%%           and, if Packet is a request record(), also check sanity
%%           of CSeq and (unless configured not to) check for a
%%           looping request.
%% Returns : true  |
%%           false |
%%           throw(), {sipparseerror, request, Header, Status, Reason}
%%--------------------------------------------------------------------
%%
%% Packet is request record()
%%
check_packet(Request, Origin) when record(Request, request), record(Origin, siporigin) ->
    {Method, Header} = {Request#request.method, Request#request.header},
    check_supported_uri_scheme(Request#request.uri, Header),
    sanity_check_contact(request, "From", Header),
    sanity_check_contact(request, "To", Header),
    case sipheader:cseq(Header) of
	{unparseable, CSeqStr} ->
	    logger:log(error, "INVALID CSeq ~p in packet from ~s", [CSeqStr, origin2str(Origin, "unknown")]),
	    throw({sipparseerror, request, Header, 400, "Invalid CSeq"});
	{CSeqNum, CSeqMethod} ->
	    case util:isnumeric(CSeqNum) of
		false ->
		    throw({sipparseerror, request, Header, 400, "CSeq number " ++
			   CSeqNum ++ " is not an integer"});
		_ -> true
	    end,
	    if
		CSeqMethod /= Method ->
		    throw({sipparseerror, request, Header, 400, "CSeq Method " ++ CSeqMethod ++
			   " does not match request Method " ++ Method});
		true -> true
	    end;
	_ ->
	    logger:log(error, "INVALID CSeq in packet from ~s", [origin2str(Origin, "unknown")]),
	    throw({sipparseerror, request, Header, 400, "Invalid CSeq"})
    end,
    case sipserver:get_env(detect_loops, true) of
	true ->
	    check_for_loop(Header, Request#request.uri, Origin);
	_ ->
	    true
    end;
%%
%% Packet is response record()
%%
check_packet(Response, Origin) when record(Response, response), record(Origin, siporigin) ->
    sanity_check_contact(response, "From", Response#response.header),
    sanity_check_contact(response, "To", Response#response.header).

%%--------------------------------------------------------------------
%% Function: check_for_loop(Header, URI, Origin)
%%           Header = term(), opaque (keylist record())
%%           URI    = term(), opaque (sipurl record())
%%           Origin  = siporigin record(), information about where
%%                     this Packet was received from
%% Descrip.: Inspect Header's Via: record(s) to make sure this is not
%%           a looping request.
%% Returns : true  |
%%           throw(), {sipparseerror, request, Header, Status, Reason}
%%--------------------------------------------------------------------
check_for_loop(Header, URI, Origin) when record(Origin, siporigin) ->
    LoopCookie = siprequest:get_loop_cookie(Header, URI, Origin#siporigin.proto),
    ViaHostname = siprequest:myhostname(),
    ViaPort = sipserver:get_listenport(Origin#siporigin.proto),
    CmpVia = #via{host=ViaHostname, port=ViaPort},

    case via_indicates_loop(LoopCookie, CmpVia, sipheader:via(Header)) of
	true ->
	    logger:log(debug, "Sipserver: Found a loop when inspecting the Via headers, "
		       "throwing SIP-serror '482 Loop Detected'"),
	    throw({sipparseerror, request, Header, 482, "Loop Detected"});
	_ ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: via_indicates_loop(LoopCookie, CmpVia, ViaList)
%%           LoopCookie = string()
%%           CmpVia     = via record(), what my Via would look like
%%           ViaList    = list() of via record()
%% Descrip.: Helper function for check_for_loop/3. See that function.
%% Returns : true  |
%%           false
%%--------------------------------------------------------------------
via_indicates_loop(_LoopCookie, _CmpVia, []) ->
    false;
via_indicates_loop(LoopCookie, CmpVia, [TopVia | Rest]) when is_record(TopVia, via)->
    case sipheader:via_is_equal(TopVia, CmpVia, [host, port]) of
	true ->
	    %% Via matches me
	    ParamDict = sipheader:param_to_dict(TopVia#via.param),
	    %% Can't use sipheader:get_via_branch() since it strips the loop cookie
	    case dict:find("branch", ParamDict) of
		error ->
		    %% XXX should broken Via perhaps be considered fatal?
		    logger:log(error, "Sipserver: Request has Via that matches me,"
			       " but no branch parameter. Loop checking broken!"),
		    logger:log(debug, "Sipserver: Via ~p matches me, but has no branch parameter."
			       " Loop checking broken!",
			       sipheader:via_print([TopVia])),
		    via_indicates_loop(LoopCookie, CmpVia, Rest);
		{ok, Branch} ->
		    case lists:suffix("-o" ++ LoopCookie, Branch) of
			true ->
			    true;
			false ->
			    %% Loop cookie does not match, check next (request might have passed
			    %% this proxy more than once, loop can be further back the via trail)
			    via_indicates_loop(LoopCookie, CmpVia, Rest)
		    end
	    end;
	_ ->
	    %% Via doesn't match me, check next.
	    via_indicates_loop(LoopCookie, CmpVia, Rest)
    end.

%%--------------------------------------------------------------------
%% Function: make_logstr(R, Origin)
%%           R      = request record() | response record()
%%           Origin = siporigin record()
%% Descrip.: Create a textual representation of a request/response,
%%           for use in logging.
%% Returns : LogStr
%%           LogStr = string()
%%--------------------------------------------------------------------
make_logstr(Request, Origin) when is_record(Request, request) ->
    {Method, URI, Header} = {Request#request.method, Request#request.uri, Request#request.header},
    {_, FromURI} = sipheader:from(Header),
    {_, ToURI} = sipheader:to(Header),
    ClientStr = origin2str(Origin, "unknown"),
    lists:flatten(io_lib:format("~s ~s [client=~s, from=<~s>, to=<~s>]",
				[Method, sipurl:print(URI), ClientStr, url2str(FromURI), url2str(ToURI)]));
make_logstr(Response, Origin) when is_record(Response, response) ->
    Header = Response#response.header,
    {_, CSeqMethod} = sipheader:cseq(Header),
    {_, FromURI} = sipheader:from(Header),
    {_, ToURI} = sipheader:to(Header),
    ClientStr = origin2str(Origin, "unknown"),
    case keylist:fetch('warning', Header) of
	[Warning] when is_list(Warning) ->
	    lists:flatten(io_lib:format("~s [client=~s, from=<~s>, to=<~s>, warning=~p]",
					[CSeqMethod, ClientStr, url2str(FromURI), url2str(ToURI), Warning]));
	_ ->
	    %% Zero or more than one Warning-headers
	    lists:flatten(io_lib:format("~s [client=~s, from=<~s>, to=<~s>]",
					[CSeqMethod, ClientStr, url2str(FromURI), url2str(ToURI)]))
    end.

url2str({unparseable, _}) ->
    "unparseable";
url2str(URL) ->
    sipurl:print(URL).

sanity_check_contact(Type, Name, Header) when Type == request; Type == response; is_list(Name),
					      is_record(Header, keylist) ->
    case keylist:fetch(Name, Header) of
	[Str] when is_list(Str) ->
	    case sipheader:from([Str]) of
		{_, URI} when is_record(URI, sipurl) ->
		    sanity_check_uri(Type, Name ++ ":", URI, Header);
		_ ->
		    throw({sipparseerror, Type, Header, 400, "Invalid " ++ Name ++ ": header"})
	    end;
	_ ->
	    %% Header is either missing, or there was more than one
	    throw({sipparseerror, Type, Header, 400, "Missing or invalid " ++ Name ++ ": header"})
    end.

sanity_check_uri(Type, Desc, URI, Header)  when is_record(URI, sipurl), URI#sipurl.host == none ->
    throw({sipparseerror, Type, Header, 400, "No host part in " ++ Desc ++ " URL"});
sanity_check_uri(_Type, _Desc, URI, _Header) when is_record(URI, sipurl) ->
    ok.

check_supported_uri_scheme({unparseable, URIstr}, Header) ->
    case string:chr(URIstr, $:) of
	0 ->
	    throw({sipparseerror, request, Header, 416, "Unsupported URI Scheme"});
	Index ->
	    Scheme = string:substr(URIstr, 1, Index),
	    throw({sipparseerror, request, Header, 416, "Unsupported URI Scheme (" ++ Scheme ++ ")"})
    end;
check_supported_uri_scheme(URI, _) when record(URI, sipurl) ->
    true.

get_env(Name) ->
    {ok, Value} = application:get_env(Name),
    Value.

get_env(Name, Default) ->
    case application:get_env(Name) of
	{ok, Value} ->
	    Value;
	undefined ->
	    Default
    end.

origin2str(Origin, _) when record(Origin, siporigin) ->
    lists:concat([Origin#siporigin.proto, ":", Origin#siporigin.addr, ":", Origin#siporigin.port]);
origin2str(Str, _) when list(Str) ->
    lists:concat([Str]);
origin2str(_F, Default) ->
    Default.

get_listenport(Proto) when Proto == tls; Proto == tls6 ->
    case sipserver:get_env(tls_listenport, none) of
	P when integer(P) ->
	    P;
	none ->
	    siprequest:default_port(Proto, none)
    end;
get_listenport(Proto) ->
    case sipserver:get_env(listenport, none) of
	P when integer(P) ->
	    P;
	none ->
	    siprequest:default_port(Proto, none)
    end.

%% In some places, we need to get a list of all ports which are valid for this proxy.
get_all_listenports() ->
    %% XXX implement the rest of this. Have to fetch a list of the ports we listen on
    %% from the transport layer.
    [get_listenport(udp)].

%%====================================================================
%% Behaviour functions
%%====================================================================

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%%--------------------------------------------------------------------


%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok | throw()
%%--------------------------------------------------------------------
test() ->
    %% build request header
    %%--------------------------------------------------------------------
    io:format("test: init variables - 1~n"),

    MyHostname = siprequest:myhostname(),
    SipPort  = sipserver:get_listenport(tcp),
    _SipsPort = sipserver:get_listenport(tls),

    ViaMe = siprequest:create_via(tcp, []),
    ViaOrigin1 = #siporigin{proto=tcp},


    %% test check_response_via(Origin, TopVia)
    %%--------------------------------------------------------------------
    io:format("test: check_response_via/2 - 1~n"),
    %% straight forward, via is what this proxy would use (ViaMe)
    ok = check_response_via(ViaOrigin1, ViaMe),

    io:format("test: check_response_via/2 - 2~n"),
    %% received response over unexpected protocol, still ok since this can
    %% happen if we for example send a request out over TCP but the other end
    %% fails to send the response back to us using the same connection so the
    %% response is received over UDP
    ok = check_response_via(ViaOrigin1#siporigin{proto=udp}, ViaMe),

    io:format("test: check_response_via/2 - 3~n"),
    %% no top via, invalid
    error = check_response_via(ViaOrigin1#siporigin{proto=udp}, none),

    %% test process_parsed_packet(Response, Origin)
    %% tests sanity_check_contact(Type, Name, Header) indirectly
    %%--------------------------------------------------------------------

    io:format("test: build response - 1~n"),
    CRHeader1 = keylist:from_list([
				    {"Via",	sipheader:via_print([ViaMe])},
				    {"Via",	["SIP/2.0/FOO 192.0.2.78"]},
				    {"From",	["<sip:user1@example.org>"]},
				    {"To",	["\"Joe\" <sip:user2@example.org>"]},
				    {"CSeq",	["10 MESSAGE"]}
				   ]),
    CheckResponse1 = #response{status=200, reason="Ok", header=CRHeader1, body=""},

    io:format("test: process_parsed_packet/2 response - 1~n"),
    %% straight forward
    {#response{}=_Response, _LogStr} = process_parsed_packet(CheckResponse1, #siporigin{proto=tcp}),
    
    io:format("test: process_parsed_packet/2 response - 2~n"),
    CRHeader2 = keylist:delete("Via", CRHeader1),
    CheckResponse2 = #response{status=200, reason="Ok", header=CRHeader2, body=""},
    %% without Via-headers
    {invalid} = process_parsed_packet(CheckResponse2, #siporigin{proto=tcp}),

    io:format("test: process_parsed_packet/2 response - 3 (disabled)~n"),
    CRHeader3 = keylist:set("From", ["http://www.example.org/"], CRHeader1),
    CheckResponse3 = #response{status=200, reason="Ok", header=CRHeader3, body=""},
    %% http From: URL, draft-ietf-sipping-torture-tests-04 argues that a proxy
    %% should be able to process a request/response with this unless the
    %% proxy really has to understand the From:. We currently don't.
    _ = (catch process_parsed_packet(CheckResponse3, #siporigin{proto=tcp})),


    %% test fix_topvia_received(Header, Origin)
    %%--------------------------------------------------------------------
    io:format("test: build request header - 1~n"),
    ReqHeader1 = keylist:from_list([{"Via", ["SIP/2.0/TLS 192.0.2.78"]}]),
    Origin1 = #siporigin{proto=tcp, addr="192.0.2.78", port=1234},
    Origin2 = #siporigin{proto=tcp, addr="192.0.2.200", port=2345},


    io:format("test: fix_topvia_received/2 - 1.1~n"),
    %% check Via that is IP-address (the right one), and no rport parameter
    ReqHeader1_1 = fix_topvia_received(ReqHeader1, Origin1),

    io:format("test: fix_topvia_received/2 - 1.2~n"),
    %% check result
    ["SIP/2.0/TLS 192.0.2.78"] = keylist:fetch(via, ReqHeader1_1),


    io:format("test: fix_topvia_received/2 - 2.1~n"),
    %% check Via that is IP-address (but not the same as in Origin2), and no rport parameter
    ReqHeader1_2 = fix_topvia_received(ReqHeader1, Origin2),

    io:format("test: fix_topvia_received/2 - 2.2~n"),
    %% check result
    ["SIP/2.0/TLS 192.0.2.78;received=192.0.2.200"] = keylist:fetch(via, ReqHeader1_2),


    io:format("test: fix_topvia_received/2 - 3.1~n"),
    ReqHeader2 = keylist:from_list([{"Via", ["SIP/2.0/TLS phone.example.org"]}]),
    io:format("test: fix_topvia_received/2 - 3.2~n"),
    %% check Via that is hostname, and no rport parameter
    ReqHeader2_1 = fix_topvia_received(ReqHeader2, Origin1),

    io:format("test: fix_topvia_received/2 - 3.3~n"),
    %% check result
    ["SIP/2.0/TLS phone.example.org;received=192.0.2.78"] = keylist:fetch(via, ReqHeader2_1),

    %% test fix_topvia_rport(Header, Origin)
    %%--------------------------------------------------------------------

    
    io:format("test: fix_topvia_rport/2 - 1.1~n"),
    ReqHeader3 = keylist:from_list([{"Via", ["SIP/2.0/TLS 192.0.2.78;rport"]}]),
    io:format("test: fix_topvia_rport/2 - 1.2~n"),
    %% check Via that is IP address, with rport. When rport exists, we MUST add a
    %% received= even if the host-part equals the address we received the request from
    ReqHeader3_1 = fix_topvia_rport(ReqHeader3, Origin1),

    io:format("test: fix_topvia_rport/2 - 1.3~n"),
    %% check result
    ["SIP/2.0/TLS 192.0.2.78;received=192.0.2.78;rport=1234"] = keylist:fetch(via, ReqHeader3_1),


    io:format("test: fix_topvia_rport/2 - 2.1~n"),
    %% check Via that is IP address (wrong address), with rport.
    ReqHeader3_2 = fix_topvia_rport(ReqHeader3, Origin2),

    io:format("test: fix_topvia_rport/2 - 2.2~n"),
    %% check result
    ["SIP/2.0/TLS 192.0.2.78;received=192.0.2.200;rport=2345"] = keylist:fetch(via, ReqHeader3_2),


    io:format("test: fix_topvia_rport/2 - 3.1~n"),
    ReqHeader4 = keylist:from_list([{"Via", ["SIP/2.0/TCP phone.example.org;rport"]}]),
    io:format("test: fix_topvia_rport/2 - 3.2~n"),
    %% check Via that is hostname, with rport.
    ReqHeader4_1 = fix_topvia_rport(ReqHeader4, Origin2),

    io:format("test: fix_topvia_rport/2 - 3.3~n"),
    %% check result
    ["SIP/2.0/TCP phone.example.org;received=192.0.2.200;rport=2345"] = keylist:fetch(via, ReqHeader4_1),


    %% build request header
    %%--------------------------------------------------------------------
    io:format("test: build request header - 1~n"),
    ReqHeader10 = keylist:from_list([
				     {"Via",	["SIP/2.0/TLS 130.237.90.1:111",
						 "SIP/2.0/TCP 2001:6b0:5:987::1"]},
				     {"From",	["<sip:test@it.su.se>;tag=f-123"]},
				     {"To",	["<sip:test@it.su.se>;tag=t-123"]},
				     {"CSeq",	["4711 INVITE"]},
				     {"Call-ID",	["abc123@test"]},
				     {"Route",	["<sip:p1:1111>", "<sip:p2:2222>"]}
				    ]),
    MyRoute = contact:parse(["<sip:" ++ MyHostname ++ ":" ++ integer_to_list(SipPort) ++ ">"]),
    MyRouteStr = contact:print(MyRoute),

    MyRoute2 = contact:parse(["<sip:" ++ siphost:myip() ++ ":" ++ integer_to_list(SipPort) ++ ">"]),
    MyRouteStr2 = contact:print(MyRoute2),

    %% port should not match me
    MyRoute3 = contact:parse(["<sip:" ++ MyHostname ++ ":4711>"]),
    MyRouteStr3 = contact:print(MyRoute3),

    %% test remove_route_matching_me(Header)
    %% indirectly tests route_matches_me(Route)
    %%--------------------------------------------------------------------

    io:format("test: remove_route_matching_me/1 - 1~n"),
    %% These two Route headers doesn't match me
    ["<sip:p1:1111>", "<sip:p2:2222>"] =
	keylist:fetch(route, remove_route_matching_me(ReqHeader10)),

    io:format("test: remove_route_matching_me/1 - 2~n"),
    %% Test a single matching Route, should result in empty route set
    [] = keylist:fetch(route, remove_route_matching_me(
				keylist:set("Route", [MyRouteStr], ReqHeader10)
				)),
    
    io:format("test: remove_route_matching_me/1 - 3~n"),
    %% Test a matching Route, and some non-matching
    ["<sip:example.org>"] = keylist:fetch(route,
					  remove_route_matching_me(
					    keylist:set("Route", [MyRouteStr, "<sip:example.org>"], ReqHeader10)
					   )),
    

    io:format("test: remove_route_matching_me/1 - 4~n"),
    %% Test a double matching Route, should result in the second one still there
    [MyRouteStr] = keylist:fetch(route, remove_route_matching_me(
					  keylist:set("Route", [MyRouteStr, MyRouteStr], ReqHeader10)
					 )),
    
    io:format("test: remove_route_matching_me/1 - 5~n"),
    %% Test Route matching on my IP address, plus one more Route
    ["<sip:example.org>"] = keylist:fetch(route,
					  remove_route_matching_me(
					    keylist:set("Route", [MyRouteStr2, "<sip:example.org>"], ReqHeader10)
					   )),

    io:format("test: remove_route_matching_me/1 - 6~n"),
    %% Test Route matching on my IP address, plus one more Route
    ["<sip:example.org>"] = keylist:fetch(route,
					  remove_route_matching_me(
					    keylist:set("Route", [MyRouteStr2, "<sip:example.org>"], ReqHeader10)
					   )),

    io:format("test: remove_route_matching_me/1 - 7~n"),
    %% Test Route with my hostname, but wrong port
    [MyRouteStr3] = keylist:fetch(route,
				  remove_route_matching_me(
				    keylist:set("Route", [MyRouteStr3], ReqHeader10)
				   )),


    %% test received_from_strict_router(URI, Header)
    %%--------------------------------------------------------------------
    io:format("test: received_from_strict_router/2 - 0~n"),
    StrictHeader1 = keylist:from_list([{"Route", ["sip:user@example.org"]}]),

    io:format("test: received_from_strict_router/2 - 1~n"),
    %% test with username part of URI, should always return false
    false = received_from_strict_router(sipurl:parse("sip:ft@example.org"), StrictHeader1),

    io:format("test: received_from_strict_router/2 - 2~n"),
    %% This is an URL that we could actually have put in a Record-Route header
    RRURL1 = "sip:" ++ MyHostname ++ ":" ++ integer_to_list(SipPort) ++ ";maddr=" ++ siphost:myip(),
    true = received_from_strict_router(sipurl:parse(RRURL1), StrictHeader1),

    io:format("test: received_from_strict_router/2 - 3~n"),
    %% This is the same URL, but without the maddr parameter. Some stacks strip RR parameters
    %% so unfortunately we must allow this one too.
    RRURL2 = "sip:" ++ MyHostname ++ ":" ++ integer_to_list(SipPort),
    false = received_from_strict_router(sipurl:parse(RRURL1), keylist:from_list([])),

    io:format("test: received_from_strict_router/2 - 4~n"),
    %% RRURL2 is a matching URL but without the maddr parameter. As some stacks strip the
    %% parameters, this one should also work even though it wouldn't by the RFC.
    true = received_from_strict_router(sipurl:parse(RRURL2), StrictHeader1),

    io:format("test: received_from_strict_router/2 - 5~n"),
    %% This is an URL that we could actually have put in a Record-Route header, but with the WRONG maddr
    RRURL3 = "sip:" ++ MyHostname ++ ":" ++ integer_to_list(SipPort) ++ ";maddr=192.0.2.123",
    false = received_from_strict_router(sipurl:parse(RRURL3), StrictHeader1),

    io:format("test: received_from_strict_router/2 - 6~n"),
    %% This is an URL that we could actually have put in a Record-Route header, but without the port
    %% which we would have put in there. Unfortunately, some stacks strip the port if it is the default
    %% port for a protocol (which SipPort should be), so we must allow this too
    RRURL4 = "sip:" ++ MyHostname ++ ";maddr=" ++ siphost:myip(),
    true = received_from_strict_router(sipurl:parse(RRURL4), StrictHeader1),


    %% test check_for_loop(Header, URI, Origin)
    %% indirectly test via_indicates_loop(LoopCookie, CmpVia, ViaList)
    %%--------------------------------------------------------------------
    Me = lists:concat([MyHostname, ":", SipPort]),

    io:format("test: check_for_loop/2 - 1~n"),
    LoopHeader1 = keylist:set("Via", ["SIP/2.0/TLS example.org:1234",
				      "SIP/2.0/TCP example.org:2222"
				     ], ReqHeader10),
    LoopURI1 = sipurl:parse("sip:user@example.org"),
    LoopOrigin1 = #siporigin{proto=tcp, addr="192.0.2.123", port=4321},
    %% No loop. No Via matches me at all.
    true = (catch check_for_loop(LoopHeader1, LoopURI1, LoopOrigin1)),

    io:format("test: check_for_loop/2 - 2~n"),
    LoopHeader2 = keylist:set("Via", ["SIP/2.0/TLS example.org:1234",
				      "SIP/2.0/TCP " ++ Me
				     ], ReqHeader10),
    %% No loop. One of the Vias match me but has no branch parameter. Maybe this should
    %% be considered cause to reject the request, but we currently don't.
    true = (catch check_for_loop(LoopHeader2, LoopURI1, LoopOrigin1)),

    io:format("test: check_for_loop/2 - 3~n"),
    LoopHeader3 = keylist:set("Via", ["SIP/2.0/TLS example.org:1234",
				      "SIP/2.0/TCP " ++ Me ++ ";branch=noloop"
				     ], ReqHeader10),
    %% No loop. The Via that matches me clearly does not have a matching loop cookie.
    true = (catch check_for_loop(LoopHeader3, LoopURI1, LoopOrigin1)),

    io:format("test: check_for_loop/2 - 4~n"),
    LoopHeader4 = keylist:set("Via", ["SIP/2.0/TLS example.org:1234",
				      "SIP/2.0/TCP " ++ Me ++ ";branch=z9hG4bK-yxa-foo-oZo99DPyZILaWA73FVsm7Dw"
				     ], ReqHeader10),
    %% Loop.
    {sipparseerror, request, _Keylst, 482, _Reason} = (catch check_for_loop(LoopHeader4, LoopURI1, LoopOrigin1)),

    io:format("test: check_for_loop/2 - 5~n"),
    LoopHeader5 = keylist:set("Via", ["SIP/2.0/TLS example.org:1234",
				      "SIP/2.0/UDP " ++ Me ++ ";branch=z9hG4bK-yxa-foo-o4711foo",
				      "SIP/2.0/TLS example.com:5090",
				      "SIP/2.0/TLS " ++ Me ++ ";received=192.0.2.1;branch="
				      "z9hG4bK-yxa-foo-oZo99DPyZILaWA73FVsm7Dw",
				      "SIP/2.0/UDP phone.example.net;received=192.0.2.254"
				     ], ReqHeader10),
    %% Loop, although a wee bit harder to spot since there is one Via matching us (UDP) that does NOT
    %% indicate a loop, and the one that does (TLS) has some unknown-to-us IP address in a received parameter.
    {sipparseerror, request, _Keylist, 482, _Reason} = 
	(catch check_for_loop(LoopHeader5, LoopURI1, LoopOrigin1)),

    %% test process_parsed_packet(Request, Origin)
    %% test check_packet(Request, Origin)

    %% test make_logstr(Request, Origin)
    %% test check_supported_uri_scheme(URI, Header)
    %% test get_env(Name)
    %% test get_env(Name, Default)
    %% test origin2str(Origin, Default)
    %% test get_listenport(Proto)
    %% test get_all_listenports()
    ok.
