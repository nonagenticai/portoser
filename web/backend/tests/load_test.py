"""
Load testing script for metrics endpoints
Tests concurrent requests to verify performance
"""

import asyncio
import time
from typing import Any, Dict

import aiohttp


async def make_request(session: aiohttp.ClientSession, url: str, request_id: int) -> Dict[str, Any]:
    """Make a single HTTP request"""
    start_time = time.time()
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=10)) as response:
            status = response.status
            elapsed = time.time() - start_time
            return {
                "request_id": request_id,
                "status": status,
                "elapsed_ms": elapsed * 1000,
                "success": 200 <= status < 300,
            }
    except Exception as e:
        elapsed = time.time() - start_time
        return {
            "request_id": request_id,
            "status": 0,
            "elapsed_ms": elapsed * 1000,
            "success": False,
            "error": str(e),
        }


async def load_test(url: str, num_requests: int = 100, concurrency: int = 10) -> Dict[str, Any]:
    """
    Perform load test with concurrent requests

    Args:
        url: URL to test
        num_requests: Total number of requests
        concurrency: Number of concurrent requests

    Returns:
        Dictionary with test results
    """
    print(f"\nLoad Test: {url}")
    print(f"Requests: {num_requests}, Concurrency: {concurrency}")
    print("-" * 60)

    connector = aiohttp.TCPConnector(limit=concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        # Create all request tasks
        tasks = [make_request(session, url, i) for i in range(num_requests)]

        # Execute with timing
        start_time = time.time()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        total_time = time.time() - start_time

    # Process results
    successful = [r for r in results if isinstance(r, dict) and r.get("success")]
    failed = [r for r in results if isinstance(r, dict) and not r.get("success")]
    errors = [r for r in results if isinstance(r, Exception)]

    # Calculate statistics
    if successful:
        response_times = [r["elapsed_ms"] for r in successful]
        avg_response = sum(response_times) / len(response_times)
        min_response = min(response_times)
        max_response = max(response_times)
        p95_response = sorted(response_times)[int(len(response_times) * 0.95)]
    else:
        avg_response = min_response = max_response = p95_response = 0

    success_rate = (len(successful) / num_requests) * 100
    requests_per_second = num_requests / total_time

    return {
        "url": url,
        "total_requests": num_requests,
        "successful": len(successful),
        "failed": len(failed),
        "errors": len(errors),
        "success_rate": success_rate,
        "total_time_s": total_time,
        "requests_per_second": requests_per_second,
        "avg_response_ms": avg_response,
        "min_response_ms": min_response,
        "max_response_ms": max_response,
        "p95_response_ms": p95_response,
    }


def print_results(results: Dict[str, Any]):
    """Print test results"""
    print("\nResults:")
    print(f"  Total Requests:     {results['total_requests']}")
    print(f"  Successful:         {results['successful']}")
    print(f"  Failed:             {results['failed']}")
    print(f"  Errors:             {results['errors']}")
    print(f"  Success Rate:       {results['success_rate']:.1f}%")
    print("\nTiming:")
    print(f"  Total Time:         {results['total_time_s']:.2f}s")
    print(f"  Requests/Second:    {results['requests_per_second']:.1f}")
    print("\nResponse Times:")
    print(f"  Average:            {results['avg_response_ms']:.1f}ms")
    print(f"  Min:                {results['min_response_ms']:.1f}ms")
    print(f"  Max:                {results['max_response_ms']:.1f}ms")
    print(f"  95th Percentile:    {results['p95_response_ms']:.1f}ms")

    # Performance benchmarks
    print("\nBenchmarks:")
    benchmarks = {"/ping": 10, "/api/health": 100, "/api/metrics/health": 100}

    for endpoint, threshold in benchmarks.items():
        if endpoint in results["url"]:
            status = "PASS" if results["avg_response_ms"] < threshold else "FAIL"
            print(f"  {endpoint} < {threshold}ms: {status} ({results['avg_response_ms']:.1f}ms)")


async def main():
    """Run load tests"""
    # Base URL - adjust if server is running on different port
    base_url = "http://localhost:8988"

    # Test endpoints
    endpoints = [
        ("/ping", 100, 20),  # URL, num_requests, concurrency
        ("/api/health", 100, 20),
    ]

    print("=" * 60)
    print("METRICS SYSTEM LOAD TESTING")
    print("=" * 60)

    all_results = []

    for endpoint, num_requests, concurrency in endpoints:
        url = f"{base_url}{endpoint}"
        try:
            results = await load_test(url, num_requests, concurrency)
            print_results(results)
            all_results.append(results)
        except Exception as e:
            print(f"\nERROR testing {endpoint}: {e}")

    # Overall summary
    print("\n" + "=" * 60)
    print("OVERALL SUMMARY")
    print("=" * 60)

    if all_results:
        total_requests = sum(r["total_requests"] for r in all_results)
        total_successful = sum(r["successful"] for r in all_results)
        overall_success = (total_successful / total_requests) * 100

        print(f"Total Requests:     {total_requests}")
        print(f"Total Successful:   {total_successful}")
        print(f"Overall Success:    {overall_success:.1f}%")
        print(f"\nStatus: {'PASS' if overall_success > 99 else 'FAIL'}")


if __name__ == "__main__":
    print("Note: This load test requires the backend server to be running.")
    print("Start the server with: uvicorn main:app --reload")
    print()

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\nTest interrupted by user")
