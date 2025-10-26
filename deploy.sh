#!/bin/bash

# 部署脚本 - 支持本地和 Kubernetes 部署
# 用法：
#   本地部署：./deploy.sh
#   Kubernetes 部署：./deploy.sh k8s

set -e

DEPLOYMENT_MODE=${1:-local}
NAMESPACE="txt-anime"
REGISTRY="aslan-spock-register.qiniu.io/qmatrix"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"

echo "🚀 开始部署 txt-anime 项目..."
echo "部署模式: $DEPLOYMENT_MODE"
echo "镜像标签: $IMAGE_TAG"
echo ""

if [ "$DEPLOYMENT_MODE" = "k8s" ]; then
    echo "📦 Kubernetes 部署模式"
    
    # 检查必要工具
    echo "📋 检查必要工具..."
    for tool in docker go kubectl; do
        if ! command -v $tool &> /dev/null; then
            echo "❌ $tool 未安装，请先安装 $tool"
            exit 1
        fi
    done
    echo "✅ 所有必要工具已就绪"
    
    # 构建后端
    echo ""
    echo "🔨 构建后端..."
    echo "  编译 Go 二进制文件..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -installsuffix cgo -o novel2comicd-linux ./cmd/novel2comicd
    if [ $? -ne 0 ]; then
        echo "❌ 后端编译失败"
        exit 1
    fi
    echo "  构建 Docker 镜像..."
    docker build -f Dockerfile.simple2 -t $REGISTRY/novel2comicd-backend:$IMAGE_TAG . > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 后端镜像构建失败"
        exit 1
    fi
    # 同时打上 latest 标签
    docker tag $REGISTRY/novel2comicd-backend:$IMAGE_TAG $REGISTRY/novel2comicd-backend:latest
    echo "  推送镜像到仓库..."
    docker push $REGISTRY/novel2comicd-backend:$IMAGE_TAG > /dev/null 2>&1
    docker push $REGISTRY/novel2comicd-backend:latest > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 后端镜像推送失败"
        exit 1
    fi
    echo "✅ 后端镜像构建并推送成功"
    
    # 构建前端
    echo ""
    echo "🔨 构建前端..."
    cd novel-to-anime-frontend
    
    # 检查是否已构建
    if [ ! -d "dist" ]; then
        echo "  安装依赖..."
        npm install > /dev/null 2>&1
    fi
    
    # 为 K8s 构建（使用空 API_BASE_URL，让前端使用相对路径）
    echo "  构建前端（使用 nginx 反向代理）..."
    rm -rf dist
    VITE_API_BASE_URL='' npm run build > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 前端构建失败"
        cd ..
        exit 1
    fi
    
    echo "  构建 Docker 镜像..."
    # 先确保有 amd64 的 nginx:alpine 镜像
    docker pull --platform linux/amd64 nginx:alpine > /dev/null 2>&1 || true
    # 使用 buildx 构建 amd64 镜像
    docker buildx build --platform linux/amd64 --pull=false -f Dockerfile.simple -t $REGISTRY/novel2comicd-frontend:$IMAGE_TAG --load . > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 前端镜像构建失败"
        cd ..
        exit 1
    fi
    # 同时打上 latest 标签
    docker tag $REGISTRY/novel2comicd-frontend:$IMAGE_TAG $REGISTRY/novel2comicd-frontend:latest
    echo "  推送镜像到仓库..."
    docker push $REGISTRY/novel2comicd-frontend:$IMAGE_TAG > /dev/null 2>&1
    docker push $REGISTRY/novel2comicd-frontend:latest > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 前端镜像推送失败"
        cd ..
        exit 1
    fi
    cd ..
    echo "✅ 前端镜像构建并推送成功"
    
    # 部署到 Kubernetes
    echo ""
    echo "☸️  部署到 Kubernetes..."
    
    # 创建命名空间
    echo "  创建命名空间..."
    kubectl apply -f k8s/namespace.yaml > /dev/null 2>&1
    
    # 部署 MongoDB
    echo "  部署 MongoDB..."
    kubectl apply -f k8s/mongodb.yaml > /dev/null 2>&1
    
    # 等待 MongoDB 就绪
    echo "  等待 MongoDB 启动..."
    kubectl wait --for=condition=ready pod -l app=mongodb -n $NAMESPACE --timeout=60s > /dev/null 2>&1 || true
    sleep 5
    
    # 部署后端
    echo "  部署后端服务..."
    kubectl apply -f k8s/backend.yaml > /dev/null 2>&1
    
    # 部署前端
    echo "  部署前端服务..."
    kubectl apply -f k8s/frontend.yaml > /dev/null 2>&1
    
    # 强制重启部署以拉取新镜像
    echo "  重启部署以应用新镜像..."
    kubectl rollout restart deployment/backend -n $NAMESPACE > /dev/null 2>&1
    kubectl rollout restart deployment/frontend -n $NAMESPACE > /dev/null 2>&1
    
    # 等待部署完成
    echo "  等待服务就绪..."
    kubectl rollout status deployment/backend -n $NAMESPACE --timeout=120s > /dev/null 2>&1
    kubectl rollout status deployment/frontend -n $NAMESPACE --timeout=120s > /dev/null 2>&1
    
    # 显示部署状态
    echo ""
    echo "📊 部署状态："
    kubectl get pods -n $NAMESPACE -o wide
    echo ""
    kubectl get svc -n $NAMESPACE
    
    echo ""
    echo "✅ Kubernetes 部署完成！"
    echo ""
    echo "📝 使用以下命令查看详细状态："
    echo "  kubectl get all -n $NAMESPACE"
    echo "  kubectl get pods -n $NAMESPACE -w"
    echo ""
    echo "🔍 查看日志："
    echo "  kubectl logs -f -n $NAMESPACE -l app=backend"
    echo "  kubectl logs -f -n $NAMESPACE -l app=mongodb"
    echo "  kubectl logs -f -n $NAMESPACE -l app=frontend"
    echo ""
    echo "🌐 端口转发以访问服务："
    echo "  kubectl port-forward -n $NAMESPACE svc/frontend 3000:80"
    echo "  kubectl port-forward -n $NAMESPACE svc/backend 8080:8080"
    echo ""
    echo "🧹 清理部署："
    echo "  kubectl delete namespace $NAMESPACE"
    
else
    echo "🐳 本地 Docker Compose 部署模式"
    
    # 检查 docker-compose 是否可用
    if ! command -v docker-compose &> /dev/null; then
        echo "❌ docker-compose 未安装，请先安装 docker-compose"
        exit 1
    fi
    
    # 停止现有容器
    echo "停止现有容器..."
    docker-compose down || true
    
    # 启动服务
    echo "启动服务..."
    docker-compose up -d
    
    # 显示状态
    echo ""
    echo "📊 容器状态："
    docker-compose ps
    
    echo ""
    echo "✅ 本地部署完成！"
    echo "前端地址: http://localhost:3000"
    echo "后端地址: http://localhost:8080"
    echo ""
    echo "使用以下命令查看日志："
    echo "  docker-compose logs -f backend"
    echo "  docker-compose logs -f frontend"
fi
