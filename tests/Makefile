all: gen-cpp gen-python

gen-cpp:
	cd tests/protos && mkdir -p ../gen/cpp && \
		protoc --cpp_out ../gen/cpp --grpc_out ../gen/cpp \
			--plugin=protoc-gen-grpc=/usr/local/bin/grpc_cpp_plugin \
			*.proto

gen-python:
	mkdir -p tests/gen/python && \
	python3 -m grpc_tools.protoc -I ./tests/protos \
		--python_out=tests/gen/python \
    --grpc_python_out=tests/gen/python \
    ./tests/protos/*.proto

clean:
	rm -rf ./tests/gen
