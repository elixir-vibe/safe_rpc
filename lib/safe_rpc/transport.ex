defmodule SafeRPC.Transport do
  @moduledoc "Transport behaviour for SafeRPC framed binaries."

  @callback connect(keyword()) :: {:ok, term()} | {:error, term()}
  @callback listen(keyword()) :: {:ok, term()} | {:error, term()}
  @callback accept(term(), timeout()) :: {:ok, term()} | {:error, term()}
  @callback send(term(), binary(), timeout()) :: :ok | {:error, term()}
  @callback recv(term(), timeout()) :: {:ok, binary()} | {:error, term()}
  @callback close(term()) :: :ok
end
