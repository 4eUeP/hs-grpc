import os
import asyncio
import grpc
import sys
import timeit

DIR = os.path.dirname(os.path.abspath(os.path.join(__file__, "..")))
sys.path.insert(0, os.path.join(DIR, "gen/python"))

import msg_pb2 as P
import AsyncSchedule_pb2_grpc as G


async def par_main_n(coro, host, port, n):
    channel = grpc.aio.insecure_channel(f"{host}:{port}")
    stub = G.ServiceStub(channel)

    background_tasks = set()

    for x in range(n):
        task = asyncio.create_task(coro(stub))
        background_tasks.add(task)
        # task.add_done_callback(background_tasks.discard)

    for t in background_tasks:
        await t


par = 0


async def slow_unary(stub):
    req = P.Request(msg="x")
    r = await stub.SlowUnary(req)
    global par
    par += 1
    print("-> ", par, r.msg)


async def dep_unary(stub):
    req = P.Request(msg="x")
    r = await stub.DepUnary(req)
    print("-> ", r.msg)


async def bidi(stub):
    async def reqs():
        for _ in range(2):
            req = P.Request(msg="hi")
            yield req

    _call = stub.BidiStream(reqs())
    count = 0
    async for r in _call:
        count += 1
        print("=> ", count)


def test_concurrent_slow_unary(host, port):
    server_delay = 1  # 1s
    repeat = 10
    t = timeit.timeit(
        lambda: asyncio.run(par_main_n(slow_unary, host, port, 32)),
        number=repeat,
    )
    # t ~= (server_delay * repeat)
    assert (server_delay * repeat - 1) <= t <= (server_delay * repeat + 1)


def test_interdependence_unary_stream(host, port):
    # NOTE: the server handler is not thread-safe
    async def tests(stub):
        for _ in range(1000):
            task1 = asyncio.create_task(bidi(stub))
            task2 = asyncio.create_task(dep_unary(stub))
            await task1
            await task2

    async def run_tests():
        channel = grpc.aio.insecure_channel(f"{host}:{port}")
        stub = G.ServiceStub(channel)
        await asyncio.wait_for(tests(stub), timeout=5)  # 5s seems enough

    asyncio.run(run_tests())


if __name__ == "__main__":
    host = "127.0.0.1"
    port = 50051

    test_concurrent_slow_unary(host, port)
    test_interdependence_unary_stream(host, port)
