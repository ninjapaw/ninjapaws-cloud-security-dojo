import { authorizeUserMutation, getUser } from "../../lib/userAuth.mjs";
import { orders, OrderError, orderId } from "../../lib/orders.mjs";

export async function POST({ request, cookies, redirect }) {
  const denied = authorizeUserMutation(request, cookies);
  if (denied) return denied;
  const wantsJson = request.headers.get("accept")?.includes("application/json");
  try {
    if (Number(request.headers.get("content-length")) > 65536)
      throw new OrderError("Order form is too large.", 413);
    const form = await request.formData();
    const username = getUser(cookies);
    const action = String(form.get("action") ?? "save");
    const id = form.get("orderId") ? orderId(form.get("orderId")) : null;
    let savedId;
    if (action === "save") {
      const items = form.getAll("itemId");
      const quantities = form.getAll("quantity");
      if (items.length !== quantities.length)
        throw new OrderError("Invalid order lines.");
      savedId = await orders.save(
        {
          customerId: form.get("customerId"),
          warehouseId: form.get("warehouseId"),
          deliveryDate: form.get("deliveryDate"),
          notes: form.get("notes"),
          requestId: form.get("requestId"),
          lines: items.map((itemId, index) => ({
            itemId,
            quantity: quantities[index],
          })),
        },
        username,
        id,
        String(form.get("revision") ?? ""),
      );
    } else {
      if (!id || form.get("confirm") !== "yes")
        throw new OrderError("Confirm the order action first.");
      savedId = await orders.transition(
        id,
        username,
        action,
        String(form.get("revision") ?? ""),
      );
    }
    const location = `/orders/${savedId}`;
    return wantsJson
      ? Response.json(
          { location },
          { headers: { "Cache-Control": "no-store" } },
        )
      : redirect(location, 303);
  } catch (error) {
    const status = error instanceof OrderError ? error.status : 503;
    const message =
      error instanceof OrderError
        ? error.message
        : "Order service is unavailable. No success is implied. Retry using the same form.";
    return wantsJson
      ? Response.json(
          { error: message },
          { status, headers: { "Cache-Control": "no-store" } },
        )
      : new Response(message, {
          status,
          headers: { "Cache-Control": "no-store" },
        });
  }
}
