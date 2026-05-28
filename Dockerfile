# 使用 openEuler 22.03 LTS SP3 作为基础镜像
FROM openeuler/openeuler:22.03

# 维护者信息
LABEL maintainer="y1our_email@example.com"

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
RUN mkdir -p /root/.pip && \
    echo "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn" > /root/.pip/pip.conf

# 编译安装 OpenSSL 1.1.1w
RUN set -ex \
    # 1. 安装编译依赖 (包含 zlib-devel, openssl-devel 等)
    && dnf install -y gcc gcc-c++ make zlib-devel bzip2-devel \
        readline-devel sqlite-cpp-devel wget curl git libffi-devel \
    \
    # 2. 下载并编译 OpenSSL 1.1.1w
    && cd /tmp \
    && wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz \
    && tar -zxvf openssl-1.1.1w.tar.gz \
    && cd openssl-1.1.1w \
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
    && dnf install -y wget tar xz-devel gcc make zlib zlib-devel openssl-devel \
    \
    # 2. 下载、解压并编译 Python
    && cd /tmp \
    && wget https://registry.npmmirror.com/-/binary/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz \
    && tar -xvf Python-${PYTHON_VERSION}.tar.xz \
    && cd Python-${PYTHON_VERSION} \
    \
    # 3. 配置编译选项 (显式指定 LDFLAGS/CPPFLAGS 解决依赖查找问题)
    && export LDFLAGS="-L/usr/local/openssl/lib -L/usr/lib64" \
    && export CPPFLAGS="-I/usr/local/openssl/include" \
    && ./configure \
        --prefix=/usr/local/python3 \
        --with-openssl=/usr/local/openssl \
        --with-system-ffi \
    \
    # 4. 编译与安装
    && make \
    && make install \
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
    && dnf install -y openssh-clients openssh-server sudo python3-dnf  \
    \
    # 3. 安装 ansible-core
    && pip3 install ansible-core====10.3.0 \
    \
    # 4. 验证安装
    && ansible --version \
    && python3 -c "import yaml; print('PyYAML C Extension (libyaml):', hasattr(yaml, 'CLoader'))" \




# 启动命令：运行 SSHD 前台进程
CMD ["/usr/sbin/sshd", "-D"]
