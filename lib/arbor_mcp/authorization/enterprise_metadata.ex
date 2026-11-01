defmodule Arbor.MCP.Authorization.EnterpriseMetadata do
  @moduledoc false

  @grant "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @profile "urn:ietf:params:oauth:grant-profile:id-jag"

  def validate(metadata) do
    with :ok <- advertised(metadata, "grant_types_supported", @grant),
         do: advertised(metadata, "authorization_grant_profiles_supported", @profile)
  end

  defp advertised(metadata, field, expected) do
    case Map.fetch(metadata, field) do
      :error ->
        :ok

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) and expected in values,
          do: :ok,
          else: {:error, :id_jag_profile_not_supported}

      _malformed ->
        {:error, :id_jag_profile_not_supported}
    end
  end
end
