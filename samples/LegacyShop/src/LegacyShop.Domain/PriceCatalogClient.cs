using System;
using System.Net;

namespace LegacyShop.Domain
{
    public class PriceCatalogClient
    {
        public string DownloadCatalog(string url)
        {
            if (url == null)
            {
                throw new ArgumentNullException("url");
            }

            using (var client = new WebClient())
            {
                return client.DownloadString(url);
            }
        }
    }
}
