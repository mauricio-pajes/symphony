defmodule SymphonyElixir.InternalPilotInventory do
  @moduledoc """
  Inventory application and Bruno evidence contract for the API-only pilot.
  """

  @files ~w(availability.json inventory.py test_inventory.py README.md)
  for name <- @files do
    @external_resource Path.expand("../../priv/pilot/inventory/#{name}", __DIR__)
  end

  @baseline Map.new(@files, fn name -> {name, File.read!(Path.expand("../../priv/pilot/inventory/#{name}", __DIR__))} end)
  @checks [
    "HTTP 200 returns available stock after subtracting reservations",
    "A fully reserved item returns zero available stock",
    "An unknown SKU returns HTTP 404 with item_not_found",
    "The existing catalog response remains compatible"
  ]
  @requirements """
  Acceptance criteria:
  - Add GET /api/items/{sku}/availability to the existing inventory service.
  - For a known SKU, return only sku, on_hand, reserved and available. Available
    stock equals on_hand minus reserved, with a minimum of zero.
  - For an unknown SKU, respond with HTTP 404 and {"error":"item_not_found"}.
  - The existing GET /api/items response stays unchanged.
  - Demonstrate HTTP 200 and HTTP 404 in the real Bruno client. Supply cURL
    commands for each request.
  """
  @demo_heading "### Bruno API demos"

  @spec baseline() :: %{String.t() => String.t()}
  def baseline, do: @baseline

  @spec requirements() :: String.t()
  def requirements, do: @requirements

  @spec checks() :: [String.t()]
  def checks, do: @checks

  @spec context() :: String.t()
  def context do
    """
    This synthetic application is a Python HTTP service backed by SQLite.
    The trusted inventory.py reads availability.json at startup. A null route
    disables availability. A route has exactly four keys: method (GET), path
    (/api/items/{sku}/availability), fields (an ordered list of response field
    names), and not_found (the lowercase error identifier). The server reads
    the requested record and computes available as max(0, on_hand - reserved).
    The trusted test_inventory.py executes four HTTP contract checks. The demo
    uses Bruno and the loopback API, and is supplied separately by the host.
    """
  end

  @spec safe_route?(term()) :: boolean()
  def safe_route?(%{"route" => %{"method" => "GET", "path" => "/api/items/{sku}/availability", "fields" => fields, "not_found" => error} = route} = config)
      when map_size(config) == 1 and map_size(route) == 4 and is_list(fields) and is_binary(error) do
    length(fields) in 1..4 and Enum.uniq(fields) == fields and
      Enum.all?(fields, &(&1 in ~w(sku on_hand reserved available))) and Regex.match?(~r/\A[a-z_]{1,40}\z/, error)
  end

  def safe_route?(_route), do: false

  @spec demos_observed?(String.t()) :: boolean()
  def demos_observed?(body) do
    with [_, available] <- Regex.run(~r/^\[Available stock in Bruno\]\(<?([^)<>]+)>?\)$/m, body),
         [_, missing] <- Regex.run(~r/^\[Unknown SKU in Bruno\]\(<?([^)<>]+)>?\)$/m, body) do
      String.contains?(body, @demo_heading) and available != missing and asset?(available) and asset?(missing)
    else
      _missing -> false
    end
  end

  @spec demos(map() | nil, String.t()) :: {:ok, String.t()} | {:error, :invalid_demo_evidence}
  def demos(%{"diff_sha256" => revision, "available" => available, "missing" => missing} = result, revision) do
    if map_size(result) == 3 and available != missing and asset?(available) and asset?(missing) do
      {:ok,
       """

       #{@demo_heading}

       [Available stock in Bruno](#{available})

       [Unknown SKU in Bruno](#{missing})

       Reproduce against the local Stockroom API on port 8767.

       ```sh
       curl -i http://127.0.0.1:8767/api/items/NOTEBOOK-01/availability
       curl -i http://127.0.0.1:8767/api/items/MISSING-99/availability
       ```
       """}
    else
      {:error, :invalid_demo_evidence}
    end
  end

  def demos(_result, _revision), do: {:error, :invalid_demo_evidence}

  @spec asset?(term()) :: boolean()
  def asset?(value) when is_binary(value) do
    Regex.match?(~r/\Ahttps:\/\/uploads\.linear\.app\/[a-zA-Z0-9_\/-]+(?:\.mp4)?\z/, value)
  end

  def asset?(_value), do: false
end
