# syntax=docker/dockerfile:1
# 使用 openEuler 22.03 LTS SP3 作为基础镜像
FROM openeuler/openeuler:22.03

# 维护者信息
LABEL maintainer="your_email@example.com"

# 设置环境变量
ENV TZ=Asia/Shanghai
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ------------------------------------------------------------------------------
# 配置代理 (构建时可传入)
# ------------------------------------------------------------------------------
ARG HTTP_PROXY
ARG HTTPS_PROXY
ENV http_proxy=$HTTP_PROXY
ENV https_proxy=$HTTPS_PROXY

# ------------------------------------------------------------------------------
# 第一阶段：配置系统源与编译安装 OpenSSL
# ------------------------------------------------------------------------------
# 将 openEuler 的 dnf 源替换为清华源
RUN sed -i 's|repo.openeuler.org|mirrors.tuna.tsinghua.edu.cn/openeuler|g' /etc/yum.repos.d/openEuler.repo \
    && dnf makecache

# 配置 pip 全局使用清华源
RUN mkdir -p /root/.pip 
COPY pip.conf /root/.pip/

# 编译安装 OpenSSL 1.1.1w
RUN set -ex \
    --mount=type=cache,target=/var/cache/yum \
    --mount=type=cache,target=/var/cache/dnf \
    # 1. 安装编译依赖 (包含 zlib-devel, openssl-devel 等)
    && dnf install -y gcc gcc-c++ make zlib-devel bzip2-devel \
        readline-devel sqlite-cpp-devel wget curl git libffi-devel 

# 设置工作目录
WORKDIR /tmp

# 定义版本变量，便于维护
ARG OPENSSL_VERSION=1.1.1w

# 关键步骤：将存放源码和编译产物的目录挂载为缓存
# target 指向容器内的目录，id 可以自定义，用于区分不同版本的缓存
RUN --mount=type=cache,target=/tmp/openssl-src,id=openssl-${OPENSSL_VERSION} \
    cd /tmp/openssl-src \
    \
    # 1. 检查源码包是否已存在，若不存在则下载
    # 这样写可以利用 BuildKit 的特性，即使 RUN 层重建，只要缓存存在，就不会重新下载
    && if [ ! -f "openssl-${OPENSSL_VERSION}.tar.gz" ]; then \
        wget https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz; \
       fi \
    \
    # 2. 检查源码目录是否已解压，若未解压则解压
    # -k 参数确保如果目录已存在文件时不报错（配合缓存使用）
    && if [ ! -d "openssl-${OPENSS_VERSION}" ]; then \
        tar -zxvf openssl-${OPENSSL_VERSION}.tar.gz; \
       fi \
    \
    # 3. 进入目录进行配置和编译
    # 注意：OpenSSL 的 make 会生成大量中间文件，缓存这些文件是加速的关键
    && cd openssl-${OPENSSL_VERSION} \
    && ./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl no-zlib \
    && make -j$(nproc) \
    && make install \
    \
    # 3. 配置系统链接和库路径
    && mv /usr/bin/openssl /usr/bin/openssl.bak 2>/dev/null || true \
    && ln -s /usr/local/openssl/bin/openssl /usr/bin/openssl \
    && echo "/usr/local/openssl/lib" >> /etc/ld.so.conf \
    && ldconfig -v 

# ------------------------------------------------------------------------------
# 第二阶段：编译安装 Python 3.10.18
# ------------------------------------------------------------------------------
ARG PYTHON_VERSION=3.10.18

RUN set -ex \
    # 1. 安装 Python 编译依赖 (确保 zlib 和 openssl-devel 存在)
    --mount=type=cache,target=/var/cache/yum \
    --mount=type=cache,target=/var/cache/dnf \
    && dnf install -y wget tar xz-devel gcc make zlib zlib-devel openssl-devel 

# 下载并解压源码（这部分通常不需要缓存，或者可以单独做下载缓存）
RUN wget https://registry.npmmirror.com/-/binary/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz \
    && tar -xvf Python-${PYTHON_VERSION}.tar.xz

# 创建并挂载构建缓存目录
# 我们指定一个专门存放中间编译产物的目录 /tmp/python-build-output
RUN --mount=type=cache,target=/tmp/python-build-output \
    cd Python-${PYTHON_VERSION} \
    # 导出必要的 openssl 依赖路径
    && export LDFLAGS="-L/usr/local/openssl/lib -L/usr/lib64" \
    && export CPPFLAGS="-I/usr/local/openssl/include" \
    # 关键步骤：使用 -C 指定构建输出目录，或者使用 VPATH 
    && mkdir -p /tmp/python-build-output \
    && ./configure \
        --prefix=/usr/local/python3 \
        --with-openssl=/usr/local/openssl \
        --with-system-ffi \
        --build=/tmp/python-build-output \
    # 在指定的输出目录中执行 make
    && make -C /tmp/python-build-output -j$(nproc) \
    && make -C /tmp/python-build-output install
    \
    # 5. 配置环境变量和动态库缓存
    && echo 'export PATH=/usr/local/python3/bin:$PATH' >> /etc/profile \
    && echo '/usr/local/python3/lib' >> /etc/ld.so.conf \
    && ldconfig \
    && source /etc/profile

# 设置默认的 Python 版本到 PATH
ENV PATH=/usr/local/python3/bin:$PATH
ENV LD_LIBRARY_PATH=/usr/local/openssl/lib:/usr/local/python3/lib:$LD_LIBRARY_PATH

# ------------------------------------------------------------------------------
# 第三阶段：安装 Ansible 及 SSH 服务
# ------------------------------------------------------------------------------
RUN set -ex \
    # 1. 一次性安装所有系统依赖
    --mount=type=cache,target=/var/cache/yum \
    --mount=type=cache,target=/var/cache/dnf \
    && dnf install -y openssh-clients openssh-server sudo python3-dnf  \
    \
    # 3. 安装 ansible-core
    --mount=type=cache,target=/root/.cache/pip \
    && pip3 install ansible-core====10.3.0 \
    \
    # 4. 验证安装
    && ansible --version \
    && python3 -c "import yaml; print('PyYAML C Extension (libyaml):', hasattr(yaml, 'CLoader'))" \




# 启动命令：运行 SSHD 前台进程
CMD ["/usr/sbin/sshd", "-D"]
