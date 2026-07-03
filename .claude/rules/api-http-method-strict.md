# iOS 后端 HTTP method + path 严格校验 · 必追 H5 store 层调用点 / `src/api` 字面 path

> 来源:
> - method:2026-07-02 wishlist stage 2 用 POST 试 `http.get` 接口 → 后端返 `code=1111 "Maybe it's GET"` → stage 3 反悔迁移 APIClient GET/DELETE
> - path:2026-06-24 callRate 真机 404(域名段错 `/api/call/*` 实为 `/api/chat/*`);2026-07-01 朋友圈 sts path 反悔(误加 `/api/` 前缀触发 404)

## 规则

iOS 后端严格校验 method 和 path(不像 H5 拦截器可灵活兜底)。**H5 侧的类型声明与文件结构都不是 iOS 的真相源,必须追字面**:

### method — 追 store/hook 层实际调用点

不看 `api/*/index.ts` **第一个导出**,追 `stores/modules/*` 或 view 内 `.then` **实际调用点**:

| H5 声明 | iOS 必须用 | 后端错误码(若错) |
|---|---|---|
| `http.get(path, {query})` | `APIClient.get(path, query:)` | `code=1111 "Maybe it's GET"` |
| `http.delete(path/id)` | `APIClient.delete("\(path)/\(id)")` | 405 或 1111 |
| `http.post(path, body)` | `APIClient.post(path, body:)` | — |

### path — 追 `src/api/{module}/index.ts` 字面 path

**禁止**从 view 的 `import { fnName } from '@/api/xxx'` + 业务模块名反推 path。必须点开 `src/api/{module}/index.ts` 拿 `http.xxx('/api/真实path', ...)` 的**字面值**。

## Why

### 三次真实反悔

- **method 错(2026-07-02 wishlist)**:H5 `api/gift/index.ts` 导出 v1/v2/v3(都 POST),实际生产用 v3(`stores/modules/gift.js:157` 调用点);v1 后端已下线,POST 会返 404。同理 wishlist 声明 `http.get`,iOS 假设"网关兼容"用 POST → `Maybe it's GET`。stage 2→3 反悔:补 APIClient GET/DELETE + Service 3 处 method 迁移
- **path 域名段错(2026-06-24 callRate)**:从"call 里的接口"直觉推 `/api/call/callRate`,真机 404;查 H5 `src/api/chat/index.ts` 才知真实字面是 `/api/chat/callRate`(chat 域,非 call 域)——H5 接口 path 与业务模块名解耦(业务在 home/online view,path 却在 `/api/user/*`;业务在 friendsCircle,path 是 `/api/expand/friendsCircle/*`)
- **path 前缀错(2026-07-01 sts)**:后端多网关并存:业务接口走 `/api/*`,**STS 服务走 `/sts/*` 无 `/api/` 前缀**(如 `/sts/getOssUploadParam`)。朋友圈上传 spec 写 `/api/sts/getOssUploadParam` → 真机 404;`sts` 命名的接口无一例外无 `/api/` 前缀,不能从其他接口举一反三推

## How to apply

iOS 侧新接口接入时(method + path 双查):

- [ ] **grep `src/api/{module}/index.ts` 拿字面 path**——不从 view import 反推、不从其他接口举一反三推。sts 命名的接口默认**无** `/api/` 前缀,业务接口默认**有**;遇到"未知前缀"直接查 H5 源或问后端,不推理
- [ ] **追 `stores/modules/*` 或 view 内实际调用点**确认版本 + method——不看 `api/*/index.ts` 第一个导出
- [ ] `http.get(...)` → `.get(path, query:)`;`http.delete(...)` → `.delete(path)`;`http.post(...)` → `.post(path, body:)`
- [ ] 真机 `code=1111` / `parameter.error` / `method not allowed` → **优先怀疑 method 错**
- [ ] 真机 **404** → **优先怀疑 path 字面写错**(前缀 / 域名段),再查后端是否下线

## 与既有规则关联

- [ios-decode-userid-compat.md](ios-decode-userid-compat.md):同源精神——"H5 `type.ts` 类型声明不可信,追真机响应";本 rule 补"H5 `api/*/index.ts` method / endpoint / path 声明都不可信,追 store 层调用点 + 字面 path"
- 本 rule 是**双闸门**——iOS Service 层新接口 method + path 一起过
