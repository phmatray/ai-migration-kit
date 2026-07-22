using System;
using LegacyShop.Domain;
using Xunit;

namespace LegacyShop.Tests
{
    public class OrderServiceTests
    {
        private readonly OrderService _service = new OrderService();

        private static Order MakeOrder()
        {
            return new Order("ORD-TEST", "test@example.com");
        }

        [Fact]
        public void ComputeTotal_SumsItemPrices()
        {
            var order = MakeOrder();
            order.AddItem(new OrderItem("A", 2, 10m));
            order.AddItem(new OrderItem("B", 1, 30m));

            Assert.Equal(50m, _service.ComputeTotal(order));
        }

        [Fact]
        public void ComputeTotal_AppliesTenPercentDiscount_Above100()
        {
            var order = MakeOrder();
            order.AddItem(new OrderItem("A", 2, 100m));

            Assert.Equal(180m, _service.ComputeTotal(order));
        }

        [Fact]
        public void ComputeTotal_NoDiscount_AtExactly100()
        {
            var order = MakeOrder();
            order.AddItem(new OrderItem("A", 1, 100m));

            Assert.Equal(100m, _service.ComputeTotal(order));
        }

        [Fact]
        public void Pay_TransitionsPendingToPaid()
        {
            var order = MakeOrder();

            _service.Pay(order);

            Assert.Equal("Paid", order.Status);
        }

        [Fact]
        public void Ship_RejectsUnpaidOrder()
        {
            var order = MakeOrder();

            Assert.Throws<InvalidOperationException>(() => _service.Ship(order));
        }

        [Fact]
        public void AddItem_RejectsNull()
        {
            var order = MakeOrder();

            Assert.Throws<ArgumentNullException>(() => order.AddItem(null));
        }
    }
}
