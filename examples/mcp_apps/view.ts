import { App, applyDocumentTheme } from "@modelcontextprotocol/ext-apps";

const app = new App({ name: "Arbor workspace plan", version: "1.0.0" });
const seats = document.querySelector<HTMLInputElement>("#seats")!;
const storage = document.querySelector<HTMLInputElement>("#storage")!;
const update = document.querySelector<HTMLButtonElement>("#update")!;
const status = document.querySelector<HTMLElement>("#status")!;
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 0, maximumFractionDigits: 2 });

function labels() {
  document.querySelector("#seats-label")!.textContent = seats.value;
  document.querySelector("#storage-label")!.textContent = `${storage.value} GB`;
}

function setInputs(args: { seats?: unknown; storageGb?: unknown }) {
  const count = args.seats === undefined ? 8 : args.seats;
  const space = args.storageGb === undefined ? 100 : args.storageGb;
  if (typeof count !== "number" || !Number.isInteger(count) || count < 1 || count > 50 ||
      typeof space !== "number" || !Number.isInteger(space) || space < 0 || space > 2000) throw new Error("Unsupported plan inputs.");
  seats.value = String(count);
  storage.value = String(space);
  labels();
}

function render(result: { structuredContent?: unknown; _meta?: Record<string, unknown>; isError?: boolean }) {
  const data = result.structuredContent as { seats?: number; storageGb?: number; totalCents?: number } | undefined;
  if (result.isError || !data || !Number.isInteger(data.seats) || !Number.isInteger(data.storageGb) || !Number.isInteger(data.totalCents)) throw new Error("The estimate could not be calculated.");
  setInputs(data);
  document.querySelector("#total")!.textContent = money.format(data.totalCents! / 100);
  document.querySelector("#summary")!.textContent = `${data.seats} seats × $18 + ${data.storageGb} GB × $0.20. Includes your whole team’s shared space.`;
  const label = result._meta?.["example/viewLabel"];
  if (typeof label === "string") document.querySelector("#view-label")!.textContent = label;
  status.textContent = "Estimate updated. Make it your own.";
  update.disabled = false;
}

app.ontoolinput = ({ arguments: args }) => {
  try {
    setInputs(args ?? {});
    status.textContent = "Calculating your estimate…";
    update.disabled = true;
  } catch (error) { status.textContent = String(error); }
};
app.ontoolresult = (result) => { try { render(result); } catch (error) { status.textContent = String(error); } };
app.onhostcontextchanged = (context) => { if (context.theme) applyDocumentTheme(context.theme); };
app.ontoolcancelled = () => { status.textContent = "Estimate cancelled. You can try again."; update.disabled = false; };
app.onteardown = async () => ({});
seats.addEventListener("input", labels);
storage.addEventListener("input", labels);
update.addEventListener("click", async (event) => {
  event.preventDefault();
  update.disabled = true;
  status.textContent = "Updating your estimate…";
  try {
    render(await app.callServerTool({ name: "update_plan", arguments: { seats: Number(seats.value), storageGb: Number(storage.value) } }));
  } catch { status.textContent = "Could not update the estimate. Please try again."; }
  finally { update.disabled = false; }
});
app.connect().then(() => {
  const theme = app.getHostContext()?.theme;
  if (theme) applyDocumentTheme(theme);
}).catch(() => { status.textContent = "Connect this tool from an MCP Apps-capable host to use the view."; });
