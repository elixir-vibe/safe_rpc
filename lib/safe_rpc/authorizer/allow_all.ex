defmodule SafeRPC.Authorizer.AllowAll do
  @moduledoc "Default SafeRPC authorizer."

  @behaviour SafeRPC.Authorizer

  @impl true
  def authorize(_request, _context), do: :ok
end
