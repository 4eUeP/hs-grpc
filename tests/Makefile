all: gen-cpp gen-python

gen-cpp:
	cd tests/protos && mkdir -p ../gen-cpp && \
		protoc --cpp_out ../gen-cpp --grpc_out ../gen-cpp \
			--plugin=protoc-gen-grpc=/usr/local/bin/grpc_cpp_plugin \
			*.proto

gen-python:
	mkdir -p tests/gen-py && \
	python3 -m grpc_tools.protoc -I ./tests/protos \
		--python_out=tests/gen-py \
    --grpc_python_out=tests/gen-py \
    ./tests/protos/*.proto

clean:
	rm -rf ./tests/gen-*
