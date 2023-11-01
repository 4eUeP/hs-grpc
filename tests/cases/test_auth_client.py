import os
import asyncio
import grpc
import sys

DIR = os.path.dirname(os.path.abspath(os.path.join(__file__, "..")))
sys.path.insert(0, os.path.join(DIR, "gen/python"))

import msg_pb2 as P
import auth_pb2_grpc as G

host = "localhost"
port = 50051
TOKEN = "Basic dXNlcjpwYXNzd2Q="

# TODO


def _load_credential_from_file(filepath):
    real_path = os.path.join(os.path.dirname(__file__), filepath)
    with open(real_path, "rb") as f:
        return f.read()


SERVER_CERTIFICATE = _load_credential_from_file("credentials/localhost.crt")
SERVER_CERTIFICATE_KEY = _load_credential_from_file("credentials/localhost.key")
ROOT_CERTIFICATE = _load_credential_from_file("credentials/root.crt")


class BasicAuth(grpc.AuthMetadataPlugin):
    def __init__(self, token):
        self.token = token

    def __call__(
        self,
        context: grpc.AuthMetadataContext,
        callback: grpc.AuthMetadataPluginCallback,
    ) -> None:
        callback((("authorization", self.token),), None)


def create_secure_channel(addr, token=None) -> grpc.aio.Channel:
    # Channel credential will be valid for the entire channel
    channel_credential = grpc.ssl_channel_credentials(
        root_certificates=ROOT_CERTIFICATE,
        # private_key=SERVER_CERTIFICATE_KEY,
        # certificate_chain=SERVER_CERTIFICATE,
    )
    # Call credential object will be invoked for every single RPC
    if token:
        call_credentials = grpc.metadata_call_credentials(
            BasicAuth(token), name="basic auth"
        )
        # Combining channel credentials and call credentials together
        composite_credentials = grpc.composite_channel_credentials(
            channel_credential,
            call_credentials,
        )
        channel = grpc.aio.secure_channel(addr, composite_credentials)
    else:
        channel = grpc.aio.secure_channel(addr, channel_credential)
    return channel


async def unary():
    channel = grpc.aio.insecure_channel(f"{host}:{port}")
    stub = G.AuthServiceStub(channel)
    req = P.Request(msg="x")
    r = await stub.Unary(req)
    assert r.msg == "x"


async def secure_unary():
    channel = create_secure_channel(f"{host}:{port}")
    stub = G.AuthServiceStub(channel)
    req = P.Request(msg="x")
    r = await stub.Unary(req)
    assert r.msg == "x"


async def secure_token_unary():
    channel = create_secure_channel(f"{host}:{port}", token=TOKEN)
    stub = G.AuthServiceStub(channel)
    req = P.Request(msg="x")
    r = await stub.Unary(req)
    assert r.msg == "x"


async def token_bidi():
    channel = grpc.aio.insecure_channel(f"{host}:{port}")
    stub = G.AuthServiceStub(channel)

    async def reqs():
        for _ in range(2):
            req = P.Request(msg="hi")
            yield req

    _call = stub.BidiStream(reqs(), metadata=[("authorization", TOKEN)])
    count = 0
    async for r in _call:
        count += 1
        print("=> ", count)


def test():
    # asyncio.run(unary())
    # asyncio.run(secure_unary())
    # asyncio.run(secure_token_unary())
    asyncio.run(token_bidi())
