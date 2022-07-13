#include <HsFFI.h>

#include <agrpc/asio_grpc.hpp>
#include <asio/awaitable.hpp>
#include <asio/detached.hpp>
#include <asio/redirect_error.hpp>
#include <asio/thread_pool.hpp>
#include <grpc/support/log.h>

#include "hs_grpc.h"

namespace hsgrpc {

bool byteBufferDumpToString(grpc::ByteBuffer& buffer, std::string& input) {
  auto size = buffer.Length();
  input.reserve(size);

  std::vector<grpc::Slice> input_slices;
  auto r = buffer.Dump(&input_slices);
  if (r.ok()) {
    for (auto& slice : input_slices) {
      input += std::string(std::begin(slice), std::end(slice));
    }
    return true;
  } else {
    return false;
  }
}

asio::awaitable<void>
reader(grpc::GenericServerAsyncReaderWriter& reader_writer,
       ChannelIn& channel) {
  while (true) {
    grpc::ByteBuffer buffer;

    if (!co_await agrpc::read(reader_writer, buffer, asio::use_awaitable)) {
      gpr_log(GPR_DEBUG, "Client is done writing.");
      // Signal the writer to complete.
      channel.close();
      break;
    }
    std::string buffer_str;
    // TODO: validate the return value of byteBufferDumpToString
    byteBufferDumpToString(buffer, buffer_str);

    if (!channel.is_open()) {
      gpr_log(GPR_DEBUG, "ChannelIn got closed.");
      break;
    }
    // Send request to writer. Using detached as completion token since we do
    // not want to wait until the writer has picked up the request.
    channel.async_send(asio::error_code{}, std::move(buffer_str),
                       asio::detached);
  }
}

// The writer will pick up reads from the reader through the channel and switch
// to the thread_pool to compute their response.
asio::awaitable<bool>
writer(grpc::GenericServerAsyncReaderWriter& reader_writer, ChannelOut& channel,
       asio::thread_pool& thread_pool) {
  bool ok{true};
  while (ok) {
    asio::error_code ec;
    auto buffer = co_await channel.async_receive(
        asio::redirect_error(asio::use_awaitable, ec));
    if (ec) {
      gpr_log(GPR_DEBUG, "ChannelOut got closed.");
      break;
    }
    // Switch to the thread_pool.
    co_await asio::post(asio::bind_executor(thread_pool, asio::use_awaitable));
    // reader_writer is thread-safe so we can just interact with it from the
    // thread_pool.
    ok = co_await agrpc::write(reader_writer, buffer, asio::use_awaitable);
    // Now we are back on the main thread.
  }
  co_return ok;
}

} // namespace hsgrpc

// ----------------------------------------------------------------------------
extern "C" {

void read_channel(hsgrpc::ChannelIn* channel, HsStablePtr mvar, HsInt cap,
                  hsgrpc::read_channel_cb_data_t* cb_data) {
  channel->async_receive(
      [mvar, cap, cb_data](asio::error_code ec, std::string&& buf) {
        if (cb_data) {
          cb_data->ec = (HsInt)ec.value();
          cb_data->buf = new std::string(buf); // delete on haskell side
        }
        hs_try_putmvar(cap, mvar);
      });
}

void write_channel(hsgrpc::ChannelOut* channel, const char* payload,
                   HsInt offset, HsInt length, HsStablePtr mvar, HsInt cap,
                   HsInt* ret_code) {
  auto replySlice = grpc::Slice(payload + offset, length); // copy constructor?
  // Also copy constructor? FIXME: does this means to be copied twice?
  auto reply = grpc::ByteBuffer(&replySlice, 1);
  channel->async_send(asio::error_code{}, std::move(reply),
                      [cap, mvar, ret_code](asio::error_code ec) {
                        *ret_code = (HsInt)ec.value();
                        hs_try_putmvar(cap, mvar);
                      });
}

void close_in_channel(hsgrpc::ChannelIn* channel) { channel->close(); }

void close_out_channel(hsgrpc::ChannelOut* channel) { channel->close(); }

// ----------------------------------------------------------------------------
} // End extern "C"
