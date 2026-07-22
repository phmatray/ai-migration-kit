using System;
using System.Collections.Generic;

namespace LegacyShop.Domain
{
    public class Order
    {
        private readonly List<OrderItem> _items = new List<OrderItem>();

        public Order(string id, string customerEmail)
        {
            if (id == null)
            {
                throw new ArgumentNullException("id");
            }
            if (customerEmail == null)
            {
                throw new ArgumentNullException("customerEmail");
            }
            Id = id;
            CustomerEmail = customerEmail;
            Status = "Pending";
        }

        public string Id { get; private set; }

        public string CustomerEmail { get; private set; }

        public string Status { get; set; }

        public IList<OrderItem> Items
        {
            get { return _items; }
        }

        public void AddItem(OrderItem item)
        {
            if (item == null)
            {
                throw new ArgumentNullException("item");
            }
            _items.Add(item);
        }
    }
}
