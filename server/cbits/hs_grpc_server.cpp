#include "hs_grpc_server.h"

#include <forward_list>
#include <iostream>
#include <thread>
#include <vector>

#include <agrpc/asio_grpc.hpp>
#include <asio/awaitable.hpp>
#include <asio/bind_executor.hpp>
#include <asio/detached.hpp>
#include <asio/experimental/awaitable_operators.hpp>
#include <asio/redirect_error.hpp>
#include <asio/thread_pool.hpp>
#include <grpc/support/log.h>
#include <grpcpp/server_builder.h>

namespace hsgrpc {
// ----------------------------------------------------------------------------

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

grpc::Status consErrReplyStatus(server_response_t& response) {
  auto status_code = static_cast<grpc::StatusCode>(response.status_code);
  grpc::Status status;
  if (response.error_msg) {
    if (!response.error_details) {
      status = grpc::Status(status_code, *response.error_msg);
      delete response.error_msg;
    } else {
      status = grpc::Status(status_code, *response.error_msg,
                            *response.error_details);
      delete response.error_msg;
      delete response.error_details;
    }
  } else {
    if (!response.error_details) {
      status = grpc::Status(status_code, "");
    } else {
      status = grpc::Status(status_code, "", *response.error_details);
      delete response.error_details;
    }
  }
  return status;
}

asio::awaitable<void>
finishGrpc(grpc::GenericServerAsyncReaderWriter& reader_writer,
           server_response_t& response) {
  auto status_code = static_cast<grpc::StatusCode>(response.status_code);
  if (status_code == grpc::StatusCode::OK) {
    co_await agrpc::finish(reader_writer, grpc::Status::OK);
  } else {
    co_await agrpc::finish(reader_writer, consErrReplyStatus(response));
  }
}

struct StreamChannel {
  grpc::GenericServerAsyncReaderWriter& reader_writer;
  ChannelIn& channel_in;
  ChannelOut& channel_out;
  server_response_t& response;

  asio::awaitable<void> reader() {
    while (true) {
      grpc::ByteBuffer buffer;

      if (!co_await agrpc::read(reader_writer, buffer, asio::use_awaitable)) {
        gpr_log(GPR_DEBUG, "Client is done writing.");
        // Signal the writer to complete.
        channel_in.close();
        break;
      }
      std::string buffer_str;
      // TODO: validate the return value of byteBufferDumpToString
      byteBufferDumpToString(buffer, buffer_str);

      if (!channel_in.is_open()) {
        gpr_log(GPR_DEBUG, "ChannelIn got closed.");
        break;
      }
      // Send request to writer. Using detached as completion token since we do
      // not want to wait until the writer has picked up the request.
      channel_in.async_send(asio::error_code{}, std::move(buffer_str),
                            asio::detached);
    }
  }

  // The writer will pick up reads from the reader through the channel and
  // switch to the thread_pool to compute their response.
  asio::awaitable<bool> writer(asio::thread_pool& thread_pool) {
    bool ok{true};
    while (ok) {
      asio::error_code ec;
      auto buffer = co_await channel_out.async_receive(
          asio::redirect_error(asio::use_awaitable, ec));
      if (ec) {
        gpr_log(GPR_DEBUG, "ChannelOut got closed.");
        ok = false;
        break;
      }
      // switch to the thread_pool
      co_await asio::post(
          asio::bind_executor(thread_pool, asio::use_awaitable));
      // reader_writer is thread-safe so we can just interact with it from the
      // thread_pool.
      ok = co_await agrpc::write(reader_writer, buffer, asio::use_awaitable);
      // Now we are back on the main thread.
    }
    gpr_log(GPR_DEBUG, "Exit bidistream writer with %s", ok ? "true" : "false");

    // FIXME: Here we finish the rpc if ChannelOut was closed.
    //
    // But how about server half-closed the stream? (server closes the
    // response stream but client continues to send data)
    if (!ok) {
      co_await finishGrpc(reader_writer, response);
    }
    co_return ok;
  }
};

struct HandlerInfo {
  StreamingType type;
  HsInt hs_handler_idx;
  bool use_thread_pool;
};

struct HsAsioHandler {
  std::unordered_map<std::string, HandlerInfo>& method_handlers;
  HsCallback& callback;
  asio::thread_pool& thread_pool;

  asio::awaitable<void>
  handleUnary(grpc::GenericServerContext& server_context,
              grpc::GenericServerAsyncReaderWriter& reader_writer,
              server_request_t& request, server_response_t& response,
              bool use_thread_pool) {
    // Wait for the request message
    grpc::ByteBuffer buffer;
    bool read_ok = co_await agrpc::read(reader_writer, buffer);
    if (!read_ok) {
      gpr_log(GPR_DEBUG, "Read failed, maybe client is done writing.");
      co_return;
    }

    // Dump buffer
    std::string input;
    bool dump_ok = byteBufferDumpToString(buffer, input);
    if (!dump_ok) {
      gpr_log(GPR_ERROR, "byteBufferDumpToString failed!.");
      co_await agrpc::finish(
          reader_writer,
          grpc::Status(grpc::StatusCode::INTERNAL, "Parsing request failed"));
      co_return;
    }
    // TODO: grpc 1.39+ support DumpToSingleSlice
    //
    // grpc::Slice slice;
    // auto r = buffer.DumpToSingleSlice(&slice);
    //
    // request.data = (uint8_t*)slice.begin();
    // request.data_size = slice.size();
    request.data = (uint8_t*)input.data();
    request.data_size = input.size();
    request.server_context = &server_context;

    if (use_thread_pool) {
      co_await asio::post(
          asio::bind_executor(thread_pool, asio::use_awaitable));
    }
    // Call haskell handler
    (*callback)(&request, &response);

    // Return to client
    auto status_code = static_cast<grpc::StatusCode>(response.status_code);
    if (status_code == grpc::StatusCode::OK) {
      if (response.data) { // can be nullptr
        auto replySlice = grpc::Slice(response.data, response.data_size);
        std::free(response.data);
        co_await agrpc::write_and_finish(
            reader_writer, grpc::ByteBuffer(&replySlice, 1),
            grpc::WriteOptions{}, grpc::Status::OK);
      } else {
        co_await agrpc::finish(reader_writer, grpc::Status::OK);
      }
    } else {
      co_await agrpc::finish(reader_writer, consErrReplyStatus(response));
    }
  }

  asio::awaitable<void>
  handleBiDiStream(grpc::GenericServerContext& server_context,
                   grpc::GenericServerAsyncReaderWriter& reader_writer,
                   server_request_t& request, server_response_t& response) {
    // TODO: let user chooses the maxBufferSize
    std::size_t maxBufferSize = 8192;
    ChannelIn channel_in{co_await asio::this_coro::executor, maxBufferSize};
    ChannelOut channel_out{co_await asio::this_coro::executor, maxBufferSize};

    request.data = nullptr;
    request.data_size = 0;
    request.channel_in = &channel_in;
    request.channel_out = &channel_out;
    request.server_context = &server_context;

    // pass initial datas to haskell
    (*callback)(&request, &response);

    using namespace asio::experimental::awaitable_operators;
    auto streamChannel =
        StreamChannel{reader_writer, channel_in, channel_out, response};
    const auto ok =
        co_await (streamChannel.reader() && streamChannel.writer(thread_pool));

    // FIXME: do we really need this guard?
    // make sure we close all chennels
    if (channel_in.is_open())
      channel_in.close();
    if (channel_out.is_open())
      channel_out.close();

    if (!ok) {
      gpr_log(GPR_DEBUG, "Client has disconnected or server is shuttingdown.");
      co_return;
    } else {
      co_await finishGrpc(reader_writer, response);
    }
  }

  asio::awaitable<void>
  operator()(grpc::GenericServerContext& server_context,
             grpc::GenericServerAsyncReaderWriter& reader_writer) {
    // -- Find handlers
    auto method = server_context.method();
    auto method_handler_ = method_handlers.find(method);
    if (method_handler_ != method_handlers.end()) {
      server_request_t request;
      server_response_t response;
      request.handler_idx = method_handler_->second.hs_handler_idx;
      switch (method_handler_->second.type) {
        case StreamingType::NonStreaming: {
          co_await handleUnary(server_context, reader_writer, request, response,
                               method_handler_->second.use_thread_pool);
          break;
        }
        case StreamingType::BiDiStreaming: {
          co_await handleBiDiStream(server_context, reader_writer, request,
                                    response);
          break;
        }
        case StreamingType::ClientStreaming:
          // TODO
          throw std::logic_error("NotImplemented");
          break;
        case StreamingType::ServerStreaming:
          // TODO
          throw std::logic_error("NotImplemented");
          break;
      } // Let compiler check that all enum values are handled.
    } else {
      co_await agrpc::finish(reader_writer,
                             grpc::Status(grpc::StatusCode::UNIMPLEMENTED,
                                          "No such handler: " + method));
      co_return;
    }
  }
};

void hs_event_notify(int& fd) {
  if (fd == -1)
    return;

  uint64_t u = 1;
  ssize_t s = write(fd, &u, sizeof(uint64_t));
  if (s != sizeof(uint64_t)) {
    gpr_log(GPR_ERROR, "write to fd %d failed!", fd);
    return;
  }
}

} // namespace hsgrpc

// ----------------------------------------------------------------------------
extern "C" {

struct CppAsioServer {
  std::unique_ptr<grpc::Server> server_;
  grpc::AsyncGenericService service_;
  std::forward_list<agrpc::GrpcContext> grpc_contexts_;
  std::vector<std::thread> server_threads_;
  std::unordered_map<std::string, hsgrpc::HandlerInfo> method_handlers_;
};

CppAsioServer*
new_asio_server(const char* host, HsInt host_len, HsInt port,
                hsgrpc::hs_ssl_server_credentials_options_t* ssl_server_opts,
                HsInt parallelism) {
  const auto total_conc = std::thread::hardware_concurrency();
  if (parallelism <= 0 || parallelism > total_conc) {
    parallelism = total_conc;
  }
  std::string server_address(std::string(host, host_len) + ":" +
                             std::to_string(port));

  CppAsioServer* server_data = new CppAsioServer;
  server_data->server_threads_.reserve(parallelism);

  grpc::ServerBuilder builder;

  for (size_t i = 0; i < parallelism; ++i) {
    server_data->grpc_contexts_.emplace_front(builder.AddCompletionQueue());
  }

  if (!ssl_server_opts) {
    builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
  } else {
    grpc::SslServerCredentialsOptions ssl_opts_;
    if (ssl_server_opts->pem_root_certs_data) {
      ssl_opts_.pem_root_certs =
          std::string(ssl_server_opts->pem_root_certs_data,
                      ssl_server_opts->pem_root_certs_len);
    }
    for (HsInt i = 0; i < ssl_server_opts->pem_key_cert_pairs_size; ++i) {
      ssl_opts_.pem_key_cert_pairs.emplace_back(
          grpc::SslServerCredentialsOptions::PemKeyCertPair{
              std::string(ssl_server_opts->pem_private_key_datas[i],
                          ssl_server_opts->pem_private_key_lens[i]),
              std::string(ssl_server_opts->pem_cert_chain_datas[i],
                          ssl_server_opts->pem_cert_chain_lens[i])});
    }
    ssl_opts_.client_certificate_request =
        ssl_server_opts->client_certificate_request;

    auto channel_creds = grpc::SslServerCredentials(ssl_opts_);
    builder.AddListeningPort(server_address, channel_creds);
  }

  builder.RegisterAsyncGenericService(&server_data->service_);

  server_data->server_ = builder.BuildAndStart();
  if (server_data->server_) {
    return server_data;
  } else {
    delete server_data;
    return nullptr;
  }
}

void run_asio_server(CppAsioServer* server,
                     // method handlers: Map[(method_path, HandlerInfo)]
                     char** method_handlers, HsInt* method_handlers_len,
                     uint8_t* method_handlers_type,
                     bool* method_handlers_use_thread_pool,
                     HsInt method_handlers_total_len,
                     // method handlers end
                     hsgrpc::HsCallback callback, int fd_on_started) {
  server->method_handlers_.reserve(method_handlers_total_len);
  for (HsInt i = 0; i < method_handlers_total_len; ++i) {
    server->method_handlers_.emplace(std::make_pair(
        std::string(method_handlers[i], method_handlers_len[i]),
        hsgrpc::HandlerInfo{hsgrpc::StreamingType(method_handlers_type[i]), i,
                            method_handlers_use_thread_pool[i]}));
  }

  auto parallelism = server->server_threads_.capacity();
  for (size_t i = 0; i < parallelism; ++i) {
    server->server_threads_.emplace_back([&, i] {
      auto& grpc_context = *std::next(server->grpc_contexts_.begin(), i);
      asio::thread_pool thread_pool{1};
      agrpc::repeatedly_request(
          server->service_,
          asio::bind_executor(grpc_context,
                              hsgrpc::HsAsioHandler{server->method_handlers_,
                                                    callback, thread_pool}));
      grpc_context.run();
    });
  }

  hsgrpc::hs_event_notify(fd_on_started);

  for (auto& thread : server->server_threads_) {
    thread.join();
  }
}

void shutdown_asio_server(CppAsioServer* server) {
  gpr_log(GPR_DEBUG, "Shutdown grpc server");
  server->server_->Shutdown();
}

void delete_asio_server(CppAsioServer* server) {
  gpr_log(GPR_DEBUG, "Delete allocated server");
  delete server;
}

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
