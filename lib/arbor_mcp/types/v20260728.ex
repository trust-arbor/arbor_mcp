defmodule Arbor.MCP.Types.V20260728 do
  @moduledoc """
  Type definitions for MCP protocol version 2026-07-28.

  This revision is a breaking, stateless protocol era. These types describe
  its wire surface. Runtime support is selected through the dual-era protocol
  modes, and rc.6 defaults new connections to `:prefer_modern`.

  Important changes represented here include per-request protocol metadata,
  typed result envelopes, discovery, caching hints, subscriptions, and
  multi-round-trip input requests.
  """

  @protocol_version "2026-07-28"

  @doc "Returns the protocol version described by this module."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @type request_id :: Arbor.MCP.Types.request_id()
  @type progress_token :: Arbor.MCP.Types.progress_token()
  @type log_level :: Arbor.MCP.Types.log_level()

  @typedoc "A value representable in JSON."
  @type json_value ::
          String.t()
          | number()
          | boolean()
          | nil
          | [json_value()]
          | %{optional(String.t()) => json_value()}

  @typedoc "A JSON object with string keys."
  @type json_object :: %{optional(String.t()) => json_value()}

  @typedoc "Any JSON Schema 2020-12 object, including extension keywords."
  @type json_schema :: map()

  @typedoc "An extensible MCP `_meta` object."
  @type meta_object :: %{optional(String.t()) => any()}

  @typedoc "Client or server implementation identity."
  @type implementation :: %{
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:websiteUrl) => String.t(),
          optional(:icons) => [Arbor.MCP.Types.V20251125.icon()]
        }

  @typedoc "Capabilities declared by a modern client on each request."
  @type client_capabilities :: %{
          optional(:experimental) => %{optional(String.t()) => json_object()},
          optional(:roots) => %{},
          optional(:sampling) => %{
            optional(:context) => json_object(),
            optional(:tools) => json_object()
          },
          optional(:elicitation) => %{
            optional(:form) => json_object(),
            optional(:url) => json_object()
          },
          optional(:extensions) => %{optional(String.t()) => json_object()}
        }

  @typedoc "Capabilities returned by a modern server from `server/discover`."
  @type server_capabilities :: %{
          optional(:experimental) => %{optional(String.t()) => json_object()},
          optional(:logging) => json_object(),
          optional(:completions) => json_object(),
          optional(:prompts) => %{
            optional(:listChanged) => boolean()
          },
          optional(:resources) => %{
            optional(:subscribe) => boolean(),
            optional(:listChanged) => boolean()
          },
          optional(:tools) => %{
            optional(:listChanged) => boolean()
          },
          optional(:extensions) => %{optional(String.t()) => json_object()}
        }

  @typedoc "Metadata required on every modern request."
  @type request_meta_object :: %{
          required(:"io.modelcontextprotocol/protocolVersion") => String.t(),
          required(:"io.modelcontextprotocol/clientCapabilities") => client_capabilities(),
          optional(:"io.modelcontextprotocol/clientInfo") => implementation(),
          optional(:"io.modelcontextprotocol/logLevel") => log_level(),
          optional(:progressToken) => progress_token(),
          optional(String.t()) => any()
        }

  @typedoc "Metadata carried by notifications, including subscription correlation."
  @type notification_meta_object :: %{
          optional(:"io.modelcontextprotocol/subscriptionId") => request_id(),
          optional(String.t()) => any()
        }

  @typedoc "Metadata carried by results."
  @type result_meta_object :: %{
          optional(:"io.modelcontextprotocol/serverInfo") => implementation(),
          optional(String.t()) => any()
        }

  @typedoc "A recognized or negotiated extension result discriminator."
  @type result_type :: String.t()

  @typedoc "Common fields present on every modern result."
  @type result :: %{
          required(:resultType) => result_type(),
          optional(:_meta) => result_meta_object(),
          optional(atom() | String.t()) => any()
        }

  @typedoc "A complete result with mandatory client-side caching hints."
  @type cacheable_result :: %{
          required(:resultType) => result_type(),
          required(:ttlMs) => non_neg_integer(),
          required(:cacheScope) => :public | :private,
          optional(:_meta) => result_meta_object(),
          optional(atom() | String.t()) => any()
        }

  @typedoc "The result of `server/discover`."
  @type discover_result :: %{
          required(:resultType) => result_type(),
          required(:ttlMs) => non_neg_integer(),
          required(:cacheScope) => :public | :private,
          required(:supportedVersions) => [String.t()],
          required(:capabilities) => server_capabilities(),
          optional(:instructions) => String.t(),
          optional(:_meta) => result_meta_object()
        }

  @typedoc "A server-initiated request embedded in an MRTR result."
  @type input_request :: %{
          required(:method) => String.t(),
          required(:params) => map()
        }

  @typedoc "A client result satisfying one server-initiated MRTR request."
  @type input_response :: map()

  @typedoc "Server-assigned input IDs mapped to requests."
  @type input_requests :: %{optional(String.t()) => input_request()}

  @typedoc "Server-assigned input IDs mapped to client results."
  @type input_responses :: %{optional(String.t()) => input_response()}

  @typedoc "Lifecycle state of a task in the official Tasks extension."
  @type task_status :: :working | :input_required | :completed | :failed | :cancelled

  @typedoc "Fields common to task handles and detailed task state."
  @type task :: %{
          required(:taskId) => String.t(),
          required(:status) => task_status(),
          required(:createdAt) => String.t(),
          required(:lastUpdatedAt) => String.t(),
          required(:ttlMs) => non_neg_integer(),
          optional(:pollIntervalMs) => non_neg_integer(),
          optional(:statusMessage) => String.t()
        }

  @typedoc "A server-directed task handle returned instead of an immediate result."
  @type create_task_result :: %{
          required(:resultType) => :task,
          required(:taskId) => String.t(),
          required(:status) => task_status(),
          required(:createdAt) => String.t(),
          required(:lastUpdatedAt) => String.t(),
          required(:ttlMs) => non_neg_integer(),
          optional(:pollIntervalMs) => non_neg_integer(),
          optional(:statusMessage) => String.t(),
          optional(:_meta) => result_meta_object()
        }

  @typedoc "Full task state embedded in `tasks/get` and `notifications/tasks`."
  @type detailed_task :: %{
          required(:taskId) => String.t(),
          required(:status) => task_status(),
          required(:createdAt) => String.t(),
          required(:lastUpdatedAt) => String.t(),
          required(:ttlMs) => non_neg_integer(),
          optional(:pollIntervalMs) => non_neg_integer(),
          optional(:statusMessage) => String.t(),
          optional(:inputRequests) => input_requests(),
          optional(:result) => json_object(),
          optional(:error) => json_object()
        }

  @typedoc "A complete result returned by `tasks/get`."
  @type get_task_result :: %{
          required(:resultType) => :complete,
          required(:taskId) => String.t(),
          required(:status) => task_status(),
          required(:createdAt) => String.t(),
          required(:lastUpdatedAt) => String.t(),
          required(:ttlMs) => non_neg_integer(),
          optional(:pollIntervalMs) => non_neg_integer(),
          optional(:statusMessage) => String.t(),
          optional(:inputRequests) => input_requests(),
          optional(:result) => json_object(),
          optional(:error) => json_object(),
          optional(:_meta) => result_meta_object()
        }

  @typedoc "Parameters for idempotently reading one task."
  @type get_task_request_params :: %{
          required(:_meta) => request_meta_object(),
          required(:taskId) => String.t()
        }

  @typedoc "Parameters for submitting responses to outstanding task inputs."
  @type update_task_request_params :: %{
          required(:_meta) => request_meta_object(),
          required(:taskId) => String.t(),
          required(:inputResponses) => input_responses()
        }

  @typedoc "Parameters for cooperatively cancelling one task."
  @type cancel_task_request_params :: %{
          required(:_meta) => request_meta_object(),
          required(:taskId) => String.t()
        }

  @typedoc "An interim result requesting additional client input."
  @type input_required_result :: %{
          required(:resultType) => result_type(),
          optional(:inputRequests) => input_requests(),
          optional(:requestState) => String.t(),
          optional(:_meta) => result_meta_object()
        }

  @typedoc "Retry fields accepted on client-initiated requests after an MRTR result."
  @type input_response_request_params :: %{
          required(:_meta) => request_meta_object(),
          optional(:inputResponses) => input_responses(),
          optional(:requestState) => String.t(),
          optional(atom() | String.t()) => any()
        }

  @typedoc "Notification categories selected by `subscriptions/listen`."
  @type subscription_filter :: %{
          optional(:toolsListChanged) => boolean(),
          optional(:promptsListChanged) => boolean(),
          optional(:resourcesListChanged) => boolean(),
          optional(:resourceSubscriptions) => [String.t()],
          optional(:taskIds) => [String.t()]
        }

  @typedoc "Parameters for `subscriptions/listen`."
  @type subscriptions_listen_request_params :: %{
          required(:_meta) => request_meta_object(),
          required(:notifications) => subscription_filter()
        }

  @typedoc "A request that opens a long-lived notification stream."
  @type subscriptions_listen_request :: %{
          required(:jsonrpc) => String.t(),
          required(:id) => request_id(),
          required(:method) => String.t(),
          required(:params) => subscriptions_listen_request_params()
        }

  @typedoc "Metadata on the graceful close result of a subscription stream."
  @type subscriptions_listen_result_meta_object :: %{
          required(:"io.modelcontextprotocol/subscriptionId") => request_id(),
          optional(:"io.modelcontextprotocol/serverInfo") => implementation(),
          optional(String.t()) => any()
        }

  @typedoc "The graceful close result for `subscriptions/listen`."
  @type subscriptions_listen_result :: %{
          required(:resultType) => result_type(),
          required(:_meta) => subscriptions_listen_result_meta_object()
        }

  @typedoc "A JSON-RPC header/body mismatch response (`-32020`)."
  @type header_mismatch_error :: %{
          required(:jsonrpc) => String.t(),
          optional(:id) => request_id(),
          required(:error) => %{
            required(:code) => -32020,
            required(:message) => String.t(),
            optional(:data) => any()
          }
        }

  @typedoc "An unsupported protocol version response (`-32022`)."
  @type unsupported_protocol_version_error :: %{
          required(:jsonrpc) => String.t(),
          optional(:id) => request_id(),
          required(:error) => %{
            required(:code) => -32022,
            required(:message) => String.t(),
            required(:data) => %{
              required(:supported) => [String.t()],
              required(:requested) => String.t()
            }
          }
        }

  @typedoc "A missing per-request client capability response (`-32021`)."
  @type missing_required_client_capability_error :: %{
          required(:jsonrpc) => String.t(),
          optional(:id) => request_id(),
          required(:error) => %{
            required(:code) => -32021,
            required(:message) => String.t(),
            required(:data) => %{
              required(:requiredCapabilities) => client_capabilities()
            }
          }
        }

  @typedoc "A tool definition using unrestricted JSON Schema 2020-12 objects."
  @type tool :: %{
          required(:name) => String.t(),
          required(:inputSchema) => json_schema(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:outputSchema) => json_schema(),
          optional(:annotations) => Arbor.MCP.Types.tool_annotations(),
          optional(:icons) => [Arbor.MCP.Types.V20251125.icon()],
          optional(:_meta) => meta_object()
        }

  @typedoc "A modern tool result whose structured content may be any JSON value."
  @type call_tool_result :: %{
          required(:resultType) => result_type(),
          required(:content) => [Arbor.MCP.Types.content()],
          optional(:structuredContent) => json_value(),
          optional(:isError) => boolean(),
          optional(:_meta) => result_meta_object()
        }

  @typedoc "The numeric elicitation schema from the 2026-07-28 generator."
  @type number_schema :: %{
          required(:type) => :number | :integer,
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:minimum) => number(),
          optional(:maximum) => number(),
          optional(:default) => number()
        }
end
