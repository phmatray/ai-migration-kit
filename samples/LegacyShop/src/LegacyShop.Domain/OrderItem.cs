using System;

namespace LegacyShop.Domain
{
    public class OrderItem
    {
        public OrderItem(string productName, int quantity, decimal unitPrice)
        {
            if (productName == null)
            {
                throw new ArgumentNullException("productName");
            }
            if (quantity <= 0)
            {
                throw new ArgumentException("Quantity must be positive.", "quantity");
            }
            ProductName = productName;
            Quantity = quantity;
            UnitPrice = unitPrice;
        }

        public string ProductName { get; private set; }

        public int Quantity { get; private set; }

        public decimal UnitPrice { get; private set; }
    }
}
