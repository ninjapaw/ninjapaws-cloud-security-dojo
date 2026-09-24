import sql from "mssql";
import { getPool } from "./db.mjs";

export class OrderError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

export function orderId(value) {
  const id = Number(value);
  if (!Number.isInteger(id) || id < 1 || id > 2147483647)
    throw new OrderError("Invalid order identifier.");
  return id;
}

export function validateDraft(input) {
  const customerId = orderId(input.customerId);
  const warehouseId = orderId(input.warehouseId);
  const deliveryDate = String(input.deliveryDate ?? "");
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(deliveryDate) ||
    !Number.isFinite(Date.parse(deliveryDate)) ||
    new Date(deliveryDate).toISOString().slice(0, 10) !== deliveryDate ||
    deliveryDate < "2000-01-01" ||
    deliveryDate > "2099-12-31"
  )
    throw new OrderError("Enter a valid requested delivery date.");
  const notes = String(input.notes ?? "").trim();
  if (notes.length > 1000)
    throw new OrderError("Notes must be 1,000 characters or fewer.");
  if (
    !Array.isArray(input.lines) ||
    !input.lines.length ||
    input.lines.length > 20
  )
    throw new OrderError("Add between 1 and 20 order lines.");
  const lines = input.lines.map((line) => {
    const itemId = orderId(line.itemId);
    const quantity = Number(line.quantity);
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10000)
      throw new OrderError(
        "Each quantity must be a whole number from 1 to 10,000.",
      );
    return { itemId, quantity };
  });
  if (new Set(lines.map((line) => line.itemId)).size !== lines.length)
    throw new OrderError("Use one line per product.");
  return { customerId, warehouseId, deliveryDate, notes, lines };
}

export function createOrderService(poolProvider = getPool, driver = sql) {
  const request = (connection, values = {}) => {
    const command = new driver.Request(connection);
    for (const [name, [type, value]] of Object.entries(values))
      command.input(name, type, value);
    return command;
  };
  const identity = (username) => {
    if (typeof username !== "string" || !username || username.length > 100)
      throw new OrderError("User sign-in required.", 401);
    return { owner: [sql.NVarChar(100), username] };
  };
  const readOrder = async (connection, id, username, lock = false) => {
    const result = await request(connection, {
      ...identity(username),
      id: [sql.Int, orderId(id)],
    }).query(`
      SELECT SalesOrderID, OrderNumber, CustomerID, WarehouseID, RequestedDeliveryDate,
        Status, Notes, Subtotal, TotalAmount, CreatedBy, CONVERT(varchar(33), ModifiedDate, 126) AS Revision
      FROM SalesOrder ${lock ? "WITH (UPDLOCK, HOLDLOCK)" : ""}
      WHERE SalesOrderID = @id AND CreatedBy = @owner AND OrderNumber LIKE 'WEB-%';`);
    if (!result.recordset[0]) throw new OrderError("Order not found.", 404);
    return result.recordset[0];
  };
  const transaction = async (work) => {
    const connection = new driver.Transaction(await poolProvider());
    await connection.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);
    try {
      const result = await work(connection);
      await connection.commit();
      return result;
    } catch (error) {
      try {
        await connection.rollback();
      } catch {}
      throw error;
    }
  };
  const checkDraft = (order, revision) => {
    if (order.Status !== "Draft")
      throw new OrderError("Only draft orders can be changed.", 409);
    if (order.Revision !== revision)
      throw new OrderError(
        "This order changed in another session. Reload before saving.",
        409,
      );
  };
  return {
    async lookups() {
      const pool = await poolProvider();
      const customers = await request(pool).query(
        "SELECT CustomerID, CustomerName FROM Customer WHERE IsActive = 1 ORDER BY CustomerName;",
      );
      const warehouses = await request(pool).query(
        "SELECT WarehouseID, WarehouseName FROM Warehouse WHERE IsActive = 1 ORDER BY WarehouseName;",
      );
      const items = await request(pool).query(
        "SELECT ItemID, ItemName, ListPrice FROM Items WHERE IsActive = 1 AND ListPrice >= 0 ORDER BY ItemName;",
      );
      return {
        customers: customers.recordset,
        warehouses: warehouses.recordset,
        items: items.recordset,
      };
    },
    async list(username) {
      const result = await request(await poolProvider(), identity(username))
        .query(`
        SELECT orders.SalesOrderID, orders.OrderNumber, customer.CustomerName, orders.OrderDate,
          orders.RequestedDeliveryDate, orders.Status, orders.TotalAmount
        FROM SalesOrder orders JOIN Customer customer ON customer.CustomerID = orders.CustomerID
        WHERE orders.CreatedBy = @owner AND orders.OrderNumber LIKE 'WEB-%'
        ORDER BY orders.SalesOrderID DESC;`);
      return result.recordset;
    },
    async get(id, username) {
      const pool = await poolProvider();
      const order = await readOrder(pool, id, username);
      const result = await request(pool, { id: [sql.Int, order.SalesOrderID] })
        .query(`
        SELECT detail.ItemID, item.ItemName, detail.Quantity, detail.UnitPrice, detail.LineTotal
        FROM SalesOrderDetail detail JOIN Items item ON item.ItemID = detail.ItemID
        WHERE detail.SalesOrderID = @id ORDER BY detail.LineNumber;`);
      return { ...order, lines: result.recordset };
    },
    async save(input, username, id = null, revision = "") {
      const draft = validateDraft(input);
      const owner = identity(username);
      const requestId = String(input.requestId ?? "");
      if (
        id === null &&
        !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
          requestId,
        )
      )
        throw new OrderError("Reload the order form before submitting.");
      return transaction(async (connection) => {
        let savedId = id === null ? null : orderId(id);
        if (savedId === null) {
          // The unique order number and serializable range lock make a retried form submission idempotent.
          const existing = await request(connection, {
            ...owner,
            number: [sql.NVarChar(50), `WEB-${requestId}`],
          }).query(
            "SELECT SalesOrderID FROM SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE OrderNumber = @number AND CreatedBy = @owner;",
          );
          if (existing.recordset.length)
            return existing.recordset[0].SalesOrderID;
        } else {
          checkDraft(
            await readOrder(connection, savedId, username, true),
            revision,
          );
        }
        const values = {
          ...owner,
          customer: [sql.Int, draft.customerId],
          warehouse: [sql.Int, draft.warehouseId],
          delivery: [sql.Date, draft.deliveryDate],
          notes: [sql.NVarChar(1000), draft.notes],
        };
        const references = await request(connection, values).query(`
          SELECT (SELECT COUNT(*) FROM Customer WHERE CustomerID = @customer AND IsActive = 1) AS Customers,
            (SELECT COUNT(*) FROM Warehouse WHERE WarehouseID = @warehouse AND IsActive = 1) AS Warehouses;`);
        if (
          references.recordset[0].Customers !== 1 ||
          references.recordset[0].Warehouses !== 1
        )
          throw new OrderError("Select an active customer and warehouse.");
        if (savedId === null) {
          const inserted = await request(connection, {
            ...values,
            number: [sql.NVarChar(50), `WEB-${requestId}`],
          }).query(`
            INSERT INTO SalesOrder (OrderNumber, CustomerID, WarehouseID, RequestedDeliveryDate, Status, Notes, CreatedBy)
            OUTPUT INSERTED.SalesOrderID VALUES (@number, @customer, @warehouse, @delivery, 'Draft', @notes, @owner);`);
          savedId = inserted.recordset[0].SalesOrderID;
        } else {
          await request(connection, { ...values, id: [sql.Int, savedId] })
            .query(`
            UPDATE SalesOrder SET CustomerID = @customer, WarehouseID = @warehouse, RequestedDeliveryDate = @delivery, Notes = @notes WHERE SalesOrderID = @id;
            DELETE FROM SalesOrderDetail WHERE SalesOrderID = @id;`);
        }
        // Price every line inside the transaction; client totals are only a preview.
        for (const [index, line] of draft.lines.entries()) {
          const inserted = await request(connection, {
            id: [sql.Int, savedId],
            line: [sql.Int, index + 1],
            item: [sql.Int, line.itemId],
            quantity: [sql.Int, line.quantity],
          }).query(`
            INSERT INTO SalesOrderDetail (SalesOrderID, LineNumber, ItemID, Quantity, UnitPrice)
            OUTPUT INSERTED.SODetailID
            SELECT @id, @line, ItemID, @quantity, ListPrice FROM Items WHERE ItemID = @item AND IsActive = 1 AND ListPrice >= 0;`);
          if (inserted.recordset.length !== 1)
            throw new OrderError(
              "One of the selected products is no longer available.",
            );
        }
        await request(connection, { id: [sql.Int, savedId] }).query(`
          UPDATE SalesOrder SET Subtotal = (SELECT SUM(LineTotal) FROM SalesOrderDetail WHERE SalesOrderID = @id),
            TotalAmount = (SELECT SUM(LineTotal) FROM SalesOrderDetail WHERE SalesOrderID = @id),
            TaxAmount = 0, ShippingAmount = 0, ModifiedDate = SYSUTCDATETIME() WHERE SalesOrderID = @id;`);
        return savedId;
      });
    },
    async transition(id, username, action, revision) {
      if (!["confirm", "cancel"].includes(action))
        throw new OrderError("Invalid order action.");
      return transaction(async (connection) => {
        const order = await readOrder(connection, id, username, true);
        const target = action === "confirm" ? "Confirmed" : "Cancelled";
        if (order.Status === target) return order.SalesOrderID;
        checkDraft(order, revision);
        const lines = await request(connection, {
          id: [sql.Int, order.SalesOrderID],
        }).query(
          "SELECT COUNT(*) AS Count FROM SalesOrderDetail WHERE SalesOrderID = @id;",
        );
        if (action === "confirm" && !lines.recordset[0].Count)
          throw new OrderError("An empty order cannot be confirmed.");
        await request(connection, {
          id: [sql.Int, order.SalesOrderID],
          status: [sql.NVarChar(20), target],
        }).query(
          "UPDATE SalesOrder SET Status = @status, ModifiedDate = SYSUTCDATETIME() WHERE SalesOrderID = @id;",
        );
        return order.SalesOrderID;
      });
    },
  };
}

export const orders = createOrderService();
