-module(albedo_http).
%% One httpc front door for provider transports: inets/ssl started per call,
%% verified TLS with SNI derived from the URL for https, plain for http.
%% Callers keep their own status matching and error strings.

-export([get/4, post/6, request/6, tls_options/1]).

get(Url, Headers, Timeout, Connect) ->
    request(get, Url, Headers, none, Timeout, Connect).

post(Url, Headers, Type, Body, Timeout, Connect) ->
    request(post, Url, Headers, {Type, Body}, Timeout, Connect).

request(Method, Url, Headers, Body, Timeout, Connect) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    UrlText = unicode:characters_to_list(Url),
    FormattedHeaders = [{to_list(K), to_list(V)} || {K, V} <- Headers],
    Request = case Body of
        none -> {UrlText, FormattedHeaders};
        {Type, Payload} -> {UrlText, FormattedHeaders, to_list(Type), iolist_to_binary(Payload)}
    end,
    Options = [{timeout, Timeout}, {connect_timeout, Connect} | transport(UrlText)],
    case httpc:request(Method, Request, Options, [{body_format, binary}]) of
        {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} ->
            {ok, {Status, ResponseHeaders, ResponseBody}};
        Error -> Error
    end.

transport(Url) ->
    case uri_string:parse(Url) of
        #{scheme := "https", host := Host} -> [{ssl, tls_options(Host)}];
        _ -> []
    end.

tls_options(Host) ->
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 5},
     {server_name_indication, unicode:characters_to_list(Host)},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

to_list(V) when is_binary(V) -> unicode:characters_to_list(V);
to_list(V) -> V.
