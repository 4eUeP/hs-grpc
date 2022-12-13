all::
	cd example/protos && mkdir -p gen-cpp && \
		protoc --cpp_out gen-cpp --grpc_out gen-cpp \
		--plugin=protoc-gen-grpc=/usr/local/bin/grpc_cpp_plugin \
		example.proto
