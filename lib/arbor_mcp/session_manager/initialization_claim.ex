defmodule Arbor.MCP.SessionManager.InitializationClaim do
  @moduledoc """
  Opaque initialization capability for one session lease and original deadline.

  The request owner must remain alive, but a scheduled callback can complete
  the claim. Completion never requires that callback to impersonate its caller.
  In runtime callbacks the capability retains the actual invocation's original
  cutoff and owner, independent of each finite service-operation wait. Explicit
  `:deadline` can shorten that cutoff; `:timeout` bounds only the store call.
  Cancellation, invocation retirement and cohort replacement revoke the retained
  claim. Outside a callback the claim keeps its finite service-call cutoff.
  """
  alias Arbor.MCP.SessionManager.SessionLease

  @enforce_keys [:lease, :token, :owner, :deadline]
  defstruct [:lease, :token, :owner, :deadline]

  @opaque t :: %__MODULE__{
            lease: SessionLease.t(),
            token: reference(),
            owner: pid(),
            deadline: integer()
          }

  @doc false
  @spec new(SessionLease.t(), reference(), pid(), integer()) :: t()
  def new(lease, token, owner, deadline),
    do: %__MODULE__{lease: lease, token: token, owner: owner, deadline: deadline}

  @doc false
  @spec validate(term(), term()) ::
          {:ok, {binary(), binary()}, reference(), pid(), integer()} | {:error, term()}
  def validate(%__MODULE__{} = claim, service) do
    with true <-
           is_pid(claim.owner) and node(claim.owner) == node() and Process.alive?(claim.owner),
         true <-
           is_integer(claim.deadline) and claim.deadline > System.monotonic_time(:millisecond),
         {:ok, key} <- SessionLease.validate(claim.lease, service, :sessions) do
      {:ok, key, claim.token, claim.owner, claim.deadline}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :stale_initialization_claim}
    end
  end

  def validate(_claim, _service), do: {:error, :invalid_initialization_claim}
end
