-module(har_redbug).
-behaviour(gen_server).

%% for escript
-export([main/1]).

%% for redbug's print_fun option
-export([trace/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%% escript entry point
main([]) ->
    %% TODO: usage instructions
    redbug:main([]);
main(Args) ->
    %% Add our special trace patterns at the end
    redbug:main(
      Args ++
          ["-print_fun",
           "har_redbug:trace/2",
           %% incoming requests through cowboy
           "cowboy_router:execute",
           "cowboy_req:body -> return",
           "cowboy_req:reply",
           %% outgoing requests through shotgun
           "shotgun:open/4",
           "shotgun:post -> return"]).

-record(state,
        {parent_pid,
         file,
         first_entry_written = false,
         outstanding_requests = #{}}).

%%% callback for redbug's print_fun option
trace(Event, 0) ->
    %% For the first event, we are called with a zero in the
    %% "accumulator".  Let's start our server and store the pid
    %% instead.
    {ok, Pid} = gen_server:start(?MODULE, self(), []),
    trace(Event, Pid);
trace(Event, Pid) when is_pid(Pid) ->
    gen_server:call(Pid, {event, Event}),
    Pid.

%%% gen_server callbacks
init(Parent) ->
    {ok, File} = file:open("redbug.har", [write]),
    write_header(File),
    _ = erlang:monitor(process, Parent),
    {ok, #state{parent_pid = Parent, file = File}}.

handle_call({event, Event}, _From, State) ->
    error_logger:info_report([{event, Event}]),
    NewState = handle_event(Event, State),
    {reply, ok, NewState}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, ParentPid, _Reason},
            State = #state{parent_pid = ParentPid, file = File}) ->
    write_footer(File),
    ok = file:close(File),
    {stop, normal, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% HAR metadata
write_header(File) ->
    {{Y,Mo,D},{H,Mi,S}} = erlang:universaltime(),
    Timestamp = io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0b.~3..0bZ",
                              [Y, Mo, D, H, Mi, S, 0]),
    %% According to the spec, the "pages" key is optional, but some
    %% viewers get upset if it's not there.
    file:write(File, ["
{
    \"log\": {
        \"version\" : \"1.2\",
        \"creator\" : {\"name\": \"redbug-har\", \"version\": \"0.1\"},
        \"pages\": [{\"startedDateTime\":\"",
                      Timestamp,
                      "\",\"id\":\"page_0\",\"title\":\"pseudo-page ",
                      Timestamp,
                      "\",\"pageTimings\":{}}],
        \"entries\": ["]).

write_footer(File) ->
    file:write(File, "]
    }
}").

%%% Event handling.
%%%
%%% The basic idea is that one event represents an HTTP request, and a
%%% subsequent event represents the response to that request.  The
%%% function process_event/3 tells us whether it's a request or a
%%% response and what type it is (currently 'cowboy' or 'shotgun'),
%%% and returns data for the HAR file, a "request" or "response"
%%% structure as appropriate.
%%%
%%% We assume that for any type+pid combination there is at most one
%%% outstanding request, and thus a response for the same type+pid is
%%% the response to that request.  Once we have the response, we can
%%% write the request+response "entry" to the HAR file.
handle_event({Tag, Data, {Pid, _}, NewTS},
             State = #state{outstanding_requests = Outstanding}) ->
    case process_event(Tag, Data, Pid) of
        {outgoing, Type, Req} ->
            {OldTS, OutstandingReq} = maps:get({Type, Pid}, Outstanding, {NewTS, #{}}),
            MergedReq = maps:merge(OutstandingReq, Req),
            State#state{outstanding_requests = maps:put({Type, Pid}, {OldTS, MergedReq}, Outstanding)};
        {response, Type, Rsp} ->
            {OldTS, OutstandingReq} = maps:get({Type, Pid}, Outstanding, {NewTS, #{}}),
            State1 = State#state{outstanding_requests = maps:remove({Type, Pid}, Outstanding)},
            State2 = write_entry(OldTS, OutstandingReq, NewTS, Rsp, State1),
            State2;
        nothing ->
            State
    end.

write_entry(ReqTS, Req, RspTS, Rsp,
            State = #state{file = File, first_entry_written = FirstEntryWritten}) ->
    FirstEntryWritten andalso (ok = file:write(File, ",\n")),
    Entry =
        #{pageref => <<"page_0">>,
          startedDateTime => timestamp(ReqTS),
          time => time_diff(RspTS, ReqTS),
          request => Req,
          response => Rsp,
          timings => timings(RspTS, ReqTS),
          cache => #{}
         },
    ok = file:write(File, jsx:encode(Entry)),
    State#state{first_entry_written = true}.

timings(RspTS, ReqTS) ->
    %% We don't actually have all data, but these fields are required...
    #{blocked => -1,
      dns => -1,
      connect => -1,
      send => 0,
      wait => time_diff(RspTS, ReqTS),
      'receive' => 0,
      ssl => -1}.

-compile({nowarn_deprecated_function, [{calendar, local_time_to_universal_time, 1}]}).

timestamp({LocalH, LocalM, LocalS, US}) ->
    %% XXX: assuming current day
    %% Let's try converting to UTC.
    %% (I know this function is deprecated, but I don't really have
    %% a way to handle the edge cases that local_time_to_universal_time_dst
    %% exposes)
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time_to_universal_time({date(), {LocalH, LocalM, LocalS}}),
    iolist_to_binary(
      io_lib:format(
        "~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0b.~6..0bZ",
        [Y, Mo, D, H, Mi, S, US])).

time_diff(TS1, TS2) ->
    Time1 = time_to_ms(TS1),
    Time2 = time_to_ms(TS2),
    Time1 - Time2.

time_to_ms({H, M, S, US}) ->
    (US div 1000) + (1000 * (S + (60 * (M + 60 * H)))).

%%% Incoming requests handled by Cowboy
process_event(call, {{cowboy_router, execute, [Req, _Env]}, _}, _Pid) ->
    %% Request headers
    Method = cowboy_method(Req),
    Url = cowboy_url(Req),
    HttpVersion = cowboy_version(Req),
    Headers = cowboy_headers(Req),
    {outgoing,
     cowboy,
     #{method => Method,
       url => Url,
       httpVersion => HttpVersion,
       queryString => [],
       headers => [#{name => Name, value => iolist_to_binary(Value)}
                   || {Name, Value} <- Headers],
       headersSize => -1,
       bodySize => -1,
       cookies => []}};
process_event(retn, {{cowboy_req, body, _}, {ok, Body, Req}}, _Pid) ->
    %% Request body - update map
    Headers = cowboy_headers(Req),
    {outgoing,
     cowboy,
     #{bodySize => iolist_size(Body),
       postData => #{mimeType => content_type(Headers),
                     text => iolist_to_binary(Body)}}};
process_event(call, {{cowboy_req, reply, [Status, Headers, Body, Req]}, _}, _Pid) ->
    %% Response
    HttpVersion = cowboy_version(Req),
    HeadersAsList = if is_map(Headers) -> maps:to_list(Headers); true -> Headers end,
    {response,
     cowboy,
     #{status => Status,
       statusText => <<>>,
       httpVersion => HttpVersion,
       headers => [#{name => Name, value => iolist_to_binary(Value)}
                   || {Name, Value} <- HeadersAsList],
       headersSize => -1,
       bodySize => iolist_size(Body),
       redirectURL => <<>>,
       cookies => [],
       content => #{mimeType => content_type(Headers),
                    size => iolist_size(Body),
                    text => iolist_to_binary(Body)}}};

%%% Outgoing requests through Shotgun

process_event(call, {{shotgun, open, [Host, Port, Scheme, _Opts]}, _}, Pid) ->
    %% Need to remember Host, Port and Scheme for future use
    %% XXX: shotgun:open was probably called at node startup, long before we started tracing!
    put({shotgun, Pid}, {Host, Port, Scheme}),
    nothing;
process_event(call, {{shotgun, post, [ShotgunPid, Path, Headers, Body, _Options]}, _}, _Pid) ->
    case get({shotgun, ShotgunPid}) of
        {Host, Port, Scheme} -> ok;
        undefined ->
            Host = "unknown-hostname",
            Port = 80,
            Scheme = http
    end,
    Method = <<"POST">>,
    Url = iolist_to_binary([lists:concat([Scheme, "://", Host, ":", Port]), Path]),
    FilteredHeaders = [#{name => list_to_binary(Name), value => list_to_binary(Value)}
                       || {Name, Value} <- Headers,
                          is_list(Name),
                          is_list(Value)],
    HttpVersion = <<"HTTP/1.1">>,
    {outgoing,
     shotgun,
     #{method => Method,
       url => Url,
       httpVersion => HttpVersion,
       queryString => [],
       headers => FilteredHeaders,
       headersSize => -1,
       bodySize => iolist_size(Body),
       cookies => [],
       postData => #{mimeType => content_type(Headers),
                     text => iolist_to_binary(Body)}}};
process_event(retn, {{shotgun, post, _}, {ok, Response}}, _Pid) ->
    HttpVersion = <<"HTTP/1.1">>,
    #{status_code := Status, body := Body, headers := Headers} = Response,
    {response,
     shotgun,
     #{status => Status,
       statusText => <<>>,
       httpVersion => HttpVersion,
       headers => [#{name => Name, value => iolist_to_binary(Value)}
                   || {Name, Value} <- Headers],
       headersSize => -1,
       bodySize => iolist_size(Body),
       redirectURL => <<>>,
       cookies => [],
       content => #{mimeType => content_type(Headers),
                    size => iolist_size(Body),
                    text => iolist_to_binary(Body)}}};


process_event(Tag, Data, _) ->
    error_logger:info_report([{ignored_tag, Tag},
                              {ignored_data, Data}]),
    nothing.

content_type(HeadersMap) when is_map(HeadersMap) ->
    maps:get(<<"content-type">>, HeadersMap, <<"application/octet-stream">>);
content_type([]) ->
    %% default value
    <<"application/octet-stream">>;
content_type([{Name, Value} | T]) ->
    NameString = to_string(Name),
    case string:to_lower(NameString) of
        "content-type" ->
            iolist_to_binary(Value);
        _ ->
            content_type(T)
    end.

to_string(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
to_string(X) ->
    unicode:characters_to_list(X).

%% Let's handle both cowboy 1 and cowboy 2.  cowboy 1 uses a record,
%% while cowboy 2 uses a map.  We include cowboy 1 in har_redbug, and
%% can thus call cowboy_req directly for records.
cowboy_method(#{method := Method}) ->
    Method;
cowboy_method(Req) when is_tuple(Req) ->
    {Method, _} = cowboy_req:method(Req),
    Method.

cowboy_url(#{scheme := Scheme, host := Host, path := Path}) ->
    iolist_to_binary([Scheme, <<"://">>, Host, Path]);
cowboy_url(Req) when is_tuple(Req) ->
    {Url, _} = cowboy_req:url(Req),
    Url.

cowboy_version(#{version := Version}) ->
    Version;
cowboy_version(Req) when is_tuple(Req) ->
    {HttpVersion, _} = cowboy_req:version(Req),
    HttpVersion.

cowboy_headers(#{headers := Headers}) ->
    maps:to_list(Headers);
cowboy_headers(Req) when is_tuple(Req) ->
    {Headers, _} = cowboy_req:headers(Req),
    Headers.
