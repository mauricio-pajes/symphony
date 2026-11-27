defmodule SymphonyElixir.InternalPilotFrontend do
  @moduledoc """
  The Stockroom catalog fixtures and browser evidence contract.
  """

  alias SymphonyElixir.InternalPilotInventory

  @files ~w(catalog.html catalog.css catalog.js ui-config.json test_catalog.py)
  for name <- @files do
    @external_resource Path.expand("../../priv/pilot/inventory/#{name}", __DIR__)
  end

  @baseline Map.new(@files, fn name -> {name, File.read!(Path.expand("../../priv/pilot/inventory/#{name}", __DIR__))} end)
  @checks [
    "Inventory loads over HTTP",
    "The catalog exposes the two stock fixtures",
    "Only the selected catalog control is enabled",
    "The browser behavior module is available"
  ]

  @spec baseline() :: %{String.t() => String.t()}
  def baseline, do: Map.merge(InternalPilotInventory.baseline(), @baseline)

  @spec checks() :: [String.t()]
  def checks, do: @checks

  @spec context() :: String.t()
  def context do
    """
    The Stockroom browser UI loads the inventory catalog and ui-config.json.
    The trusted catalog.js already contains both interactions behind switches.
    The editable release configuration has exactly two Boolean keys,
    filter_in_stock and sort_by_stock, both false in the baseline.
    Only enable the control named in the requirements and leave the other off.
    Browser interaction evidence is supplied separately by the host.
    """
  end

  @spec requirements(:ui_filter | :ui_sort) :: String.t()
  def requirements(:ui_filter) do
    """
    Acceptance criteria:
    - Show the In stock only toggle in the inventory catalog.
    - Keep it off by default and show both items initially.
    - Turning it on hides the fully reserved item and updates the count.
    - Turning it off restores both rows. The toggle exposes its pressed state.
    """
  end

  def requirements(:ui_sort) do
    """
    Acceptance criteria:
    - Show a Sort by control in the inventory catalog.
    - Keep the default catalog order and both rows on first load.
    - Selecting Lowest availability moves the fully reserved item to the top.
    - Selecting Catalog order restores the original ordering without dropping a row.
    """
  end

  @spec scenario(:ui_filter | :ui_sort) :: String.t()
  def scenario(:ui_filter), do: "filter"
  def scenario(:ui_sort), do: "sort"

  @spec safe_config?(term()) :: boolean()
  def safe_config?(%{"filter_in_stock" => filter, "sort_by_stock" => sort} = config),
    do: map_size(config) == 2 and is_boolean(filter) and is_boolean(sort)

  def safe_config?(_other), do: false

  @spec demo(map() | nil, String.t()) :: {:ok, String.t()} | {:error, :invalid_demo_evidence}
  def demo(%{"diff_sha256" => revision, "video" => asset} = result, revision) do
    if map_size(result) == 2 and InternalPilotInventory.asset?(asset) do
      {:ok, "\n### Browser demo\n\n[Stockroom browser walkthrough](#{asset})\n"}
    else
      {:error, :invalid_demo_evidence}
    end
  end

  def demo(_result, _revision), do: {:error, :invalid_demo_evidence}

  @spec demo_observed?(String.t()) :: boolean()
  def demo_observed?(body) do
    case Regex.run(~r/^\[Stockroom browser walkthrough\]\(<?([^)<>]+)>?\)$/m, body) do
      [_, asset] -> String.contains?(body, "### Browser demo") and InternalPilotInventory.asset?(asset)
      _missing -> false
    end
  end
end
