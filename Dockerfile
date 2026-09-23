FROM alpine:3.20

RUN apk add --no-cache \
    lua5.1 \
    lua5.1-dev \
    luarocks5.1 \
    build-base \
    openssl-dev \
    unzip \
    zlib-dev \
    lua5.1-lzlib \
    openssl

RUN luarocks-5.1 install luafilesystem \
 && luarocks-5.1 install dkjson \
 && luarocks-5.1 install pegasus ZLIB_INCDIR=/usr/include

RUN ln -sf /usr/bin/lua5.1 /usr/bin/lua5.3

WORKDIR /app

COPY crud_server.lua /app/

EXPOSE 8080

CMD ["lua5.1", "crud_server.lua"]
