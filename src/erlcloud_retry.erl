%% -*- mode: erlang;erlang-indent-level: 4;indent-tabs-mode: nil -*-

%% @author Ransom Richardson <ransom@ransomr.net>
%% @doc
%%
%% Implementation of retry logic for AWS requests
%%
%% Currently only used for S3, but will be extended to other services in the furture.
%%
%% The pluggable retry function provides a way to customize the retry behavior, as well
%% as log and customize errors that are generated by erlcloud.
%%
%% @end

-module(erlcloud_retry).

-include("erlcloud_aws.hrl").

%% Helpers
-export([no_retry/1,
         default_retry/1,

         only_http_errors/1,
         lambda_fun_errors/1
        ]).
-export_type([should_retry/0, retry_fun/0, response_type_fun/0]).

-type should_retry() :: {retry | error, #aws_request{}}.
-type retry_fun() :: fun((#aws_request{}) -> should_retry()).
-type response_type_fun() :: fun((#aws_request{}) -> ok | error).

%% Internal impl api
-export([request/3]).

%% Error returns maintained for backwards compatibility
-spec no_retry(#aws_request{}) -> {error, #aws_request{}}.
no_retry(Request) ->
    {error, Request}.

-spec default_retry(#aws_request{}) -> should_retry().
default_retry(#aws_request{should_retry = false} = Request) ->
    {error, Request};
default_retry(#aws_request{attempt = Attempt} = Request) ->
    erlcloud_util:backoff(Attempt),
    {retry, Request}.

request(Config, #aws_request{attempt = 0} = Request, ResultFun) ->
    MaxAttempts = Config#aws_config.retry_num,
    request_and_retry(Config, ResultFun, {retry, Request}, MaxAttempts).

-spec only_http_errors(#aws_request{}) -> ok | error.
only_http_errors(#aws_request{response_status=Status})
  when Status >= 200, Status < 300
       ->
    ok;
only_http_errors(_) ->
    error.

-spec lambda_fun_errors(#aws_request{}) -> ok | error.
lambda_fun_errors(#aws_request{response_status=Status, response_headers=ResponseHeaders})
  when Status >= 200, Status < 300
       ->
    case lists:keymember("x-amz-function-error", 1, ResponseHeaders) of
        true ->
            error;
        false ->
            ok
    end;
lambda_fun_errors(_) ->
    error.

request_and_retry(_, _, {_, Request}, 0) ->
    Request;
request_and_retry(_, _, {error, Request}, _) ->
    Request;
request_and_retry(Config, ResultFun, {retry, Request}, MaxAttempts) ->
    #aws_request{
       attempt = Attempt,
       uri = URI,
       method = Method,
       request_headers = Headers,
       request_body = Body
      } = Request,
    Request2 = Request#aws_request{attempt = Attempt + 1},
    RetryFun = Config#aws_config.retry,
    ResponseTypeFun = Config#aws_config.retry_response_type,
    Rsp = erlcloud_httpc:request(URI, Method, Headers, Body,
        erlcloud_aws:get_timeout(Config), Config),
    case Rsp of
        {ok, {{Status, StatusLine}, ResponseHeaders, ResponseBody}} ->
            Request3 = Request2#aws_request{
                 error_type = aws,
                 response_status = Status,
                 response_status_line = StatusLine,
                 response_headers = ResponseHeaders,
                 response_body = ResponseBody},
            ResponseType = ResponseTypeFun(Request3),
            Request4 = ResultFun(Request3#aws_request{response_type=ResponseType}),
            case Request4#aws_request.response_type of
                ok ->
                    Request4;
                error ->
                    request_and_retry(
                        Config,
                        ResultFun,
                        RetryFun(Request4),
                        MaxAttempts - 1)
            end;
        {error, Reason} ->
            Request4 = Request2#aws_request{
                         response_type = error,
                         error_type = httpc,
                         httpc_error_reason = Reason},
            request_and_retry(
                Config,
                ResultFun,
                RetryFun(Request4),
                MaxAttempts - 1)
    end.
