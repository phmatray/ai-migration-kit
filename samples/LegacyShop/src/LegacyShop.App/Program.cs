using System;
using LegacyShop.Domain;

namespace LegacyShop.App
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var service = new OrderService();
            var order = new Order("ORD-001", "alice@example.com");
            order.AddItem(new OrderItem("Keyboard", 1, 79.90m));
            order.AddItem(new OrderItem("Mouse", 2, 24.50m));

            decimal total = service.ComputeTotal(order);
            Console.WriteLine("Order " + order.Id + " total: " + total.ToString("0.00"));

            service.Pay(order);
            service.Ship(order);
            Console.WriteLine("Order " + order.Id + " status: " + order.Status);
        }
    }
}
