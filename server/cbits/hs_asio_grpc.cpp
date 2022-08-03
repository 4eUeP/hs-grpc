#include <HsFFI.h>

#include <agrpc/asio_grpc.hpp>
#include <boost/asio/spawn.hpp>

#include <forward_list>
#include <iostream>
#include <thread>
#include <vector>

#include "hs_grpc.h"

namespace asio = boost::asio;

namespace hsgrpc {

struct HsAsioProcessor {
  using executor_type = agrpc::GrpcContext::executor_type;

  agrpc::GrpcContext& grpc_context;
  static HsCallback callback;

  static void
  handle_generic_request(grpc::GenericServerContext& server_context,
                         grpc::GenericServerAsyncReaderWriter reader_writer,
                         const asio::yield_context& yield) {
    grpc::ByteBuffer buffer;
    auto method = server_context.method();

    // -- Wait for the request message
    agrpc::read(reader_writer, buffer, yield);

    // -- Process the request message
    auto size = buffer.Length();

    std::vector<grpc::Slice> input_slices;
    std::string input;
    input.reserve(size);
    // TODO: grpc 1.39+ support DumpToSingleSlice
    buffer.Dump(&input_slices);
    for (auto& slice : input_slices) {
      input += std::string(std::begin(slice), std::end(slice));
    }

    server_request_t request;
    server_response_t response;

    request.data = (uint8_t*)input.data();
    request.data_size = input.size();
    request.method = (uint8_t*)method.data();
    request.method_size = method.size();

    // TODO: if (!callback) ...
    (*callback)(&request, &response);

    // -- Write the response message and finish this RPC with OK
    StreamingType streaming_type = response.streaming_type;
    switch (streaming_type) {
      case StreamingType::NonStreaming: {
        auto replySlice = grpc::Slice(response.data, response.data_size);
        std::free(response.data);
        agrpc::write_and_finish(reader_writer, grpc::ByteBuffer(&replySlice, 1),
                                grpc::WriteOptions{}, grpc::Status::OK, yield);
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
      case StreamingType::BiDiStreaming:
        // TODO
        throw std::logic_error("NotImplemented");
        break;
    } // Let compiler check that all enum values are handled.
  }

  void operator()(agrpc::GenericRepeatedlyRequestContext<>&& context) const {
    asio::spawn(grpc_context,
                [context = std::move(context)](asio::yield_context yield) {
                  handle_generic_request(context.server_context(),
                                         context.responder(), yield);
                });
  }

  auto get_executor() const noexcept { return grpc_context.get_executor(); }
};

HsCallback HsAsioProcessor::callback;

} // namespace hsgrpc

// ----------------------------------------------------------------------------
extern "C" {

struct CppAsioServer {
  std::unique_ptr<grpc::Server> server_;
  grpc::AsyncGenericService service_;
  std::forward_list<agrpc::GrpcContext> grpc_contexts_;
  std::vector<std::thread> server_threads_;
};

CppAsioServer* new_asio_server(const char* host, HsInt host_len, HsInt port,
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

  builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
  builder.RegisterAsyncGenericService(&server_data->service_);

  server_data->server_ = builder.BuildAndStart();
  if (server_data->server_) {
    std::cout << "Server listening on " << server_address << std::endl;
    return server_data;
  } else {
    delete server_data;
    return nullptr;
  }
}

void run_asio_server(CppAsioServer* server, hsgrpc::HsCallback callback) {
  auto parallelism = server->server_threads_.capacity();

  hsgrpc::HsAsioProcessor::callback = callback;

  for (size_t i = 0; i < parallelism; ++i) {
    server->server_threads_.emplace_back([&, i] {
      auto& grpc_context = *std::next(server->grpc_contexts_.begin(), i);
      agrpc::repeatedly_request(server->service_,
                                hsgrpc::HsAsioProcessor{grpc_context});
      grpc_context.run();
    });
  }

  for (auto& thread : server->server_threads_) {
    thread.join();
  }
}

void shutdown_asio_server(CppAsioServer* server) {
  server->server_->Shutdown();
}

void delete_asio_server(CppAsioServer* server) { delete server; }

// ----------------------------------------------------------------------------
} // End extern "C"
