using System;

namespace LegacyShop.Domain
{
    public class OrderService
    {
        public decimal ComputeTotal(Order order)
        {
            if (order == null)
            {
                throw new ArgumentNullException("order");
            }

            decimal total = 0m;
            for (int i = 0; i < order.Items.Count; i++)
            {
                OrderItem item = order.Items[i];
                total = total + (item.UnitPrice * item.Quantity);
            }

            if (total > 100m)
            {
                total = total * 0.9m;
            }

            return total;
        }

        public void Pay(Order order)
        {
            if (order == null)
            {
                throw new ArgumentNullException("order");
            }
            if (order.Status != "Pending")
            {
                throw new InvalidOperationException("Only pending orders can be paid. Current status: " + order.Status);
            }
            order.Status = "Paid";
        }

        public void Ship(Order order)
        {
            if (order == null)
            {
                throw new ArgumentNullException("order");
            }
            if (order.Status != "Paid")
            {
                throw new InvalidOperationException("Only paid orders can be shipped. Current status: " + order.Status);
            }
            order.Status = "Shipped";
        }
    }
}
