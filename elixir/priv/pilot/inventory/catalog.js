const table = document.querySelector("table");
const rows = table.querySelector("tbody");
const status = document.querySelector('[role="status"]');
const controls = document.querySelector("#controls");

let onlyAvailable = false;
let sort = "catalog";

async function read(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error("Inventory request failed");
  return response.json();
}

function appendCell(row, tag, value) {
  const cell = document.createElement(tag);
  cell.textContent = value;
  if (tag === "th") cell.scope = "row";
  row.append(cell);
}

try {
  const [{ items }, settings] = await Promise.all([read("/api/catalog"), read("/ui-config.json")]);

  function render() {
    const shown = items.filter(({ available }) => !onlyAvailable || available > 0);
    if (sort === "stock") shown.sort((left, right) => left.available - right.available);
    rows.replaceChildren();
    for (const item of shown) {
      const row = rows.insertRow();
      if (item.available === 0) row.className = "unavailable";
      appendCell(row, "th", item.name);
      appendCell(row, "td", item.sku);
      appendCell(row, "td", item.available ? String(item.available) + " available" : "Out of stock");
    }
    status.textContent = shown.length ? `${shown.length} of ${items.length} items` : "No items are available.";
    table.hidden = !shown.length;
  }

  if (settings.filter_in_stock) {
    const filter = document.createElement("button");
    filter.type = "button";
    filter.textContent = "In stock only";
    filter.setAttribute("aria-pressed", "false");
    filter.addEventListener("click", () => {
      onlyAvailable = !onlyAvailable;
      filter.setAttribute("aria-pressed", String(onlyAvailable));
      render();
    });
    controls.append(filter);
  }

  if (settings.sort_by_stock) {
    const order = document.createElement("fieldset");
    const legend = document.createElement("legend");
    legend.textContent = "Sort by";
    order.append(legend);
    for (const [value, name] of [["catalog", "Catalog order"], ["stock", "Lowest availability"]]) {
      const label = document.createElement("label");
      const option = document.createElement("input");
      option.type = "radio";
      option.name = "stock-order";
      option.value = value;
      option.checked = value === sort;
      option.addEventListener("change", () => {
        sort = option.value;
        render();
      });
      label.append(option, name);
      order.append(label);
    }
    controls.append(order);
  }

  render();
} catch {
  status.textContent = "Inventory could not load. Refresh to try again.";
}
