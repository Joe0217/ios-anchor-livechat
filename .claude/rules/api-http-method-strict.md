# iOS 后端 HTTP method 严格校验 · 必对齐 H5 store 层实际调用

> 来源：2026-07-02 stage 2 用 POST 试 `/api/live/wish/template/list` → 后端返 `{"code":"1111","message":"Please check your method type, Maybe it's GET"}` → stage 3 反悔迁移 APIClient GET/DELETE

## 规则

**iOS 后端严格按 H5 声明的 method 校验**（不像 H5 拦截器可灵活兜底）。定接口 method 时**不看 `api/*/index.ts` 第一个导出**，追 **store/hook 层实际调用点**：

| H5 声明 | iOS 必须用 | 后端错误码（若错） |
|---|---|---|
| `http.get(path, {query})` | `APIClient.get(path, query:)` | `code=1111 "Maybe it's GET"` |
| `http.delete(path/id)` | `APIClient.delete("\(path)/\(id)")` | 405 或 1111 |
| `http.post(path, body)` | `APIClient.post(path, body:)` | — |

## Why

H5 `api/gift/index.ts` 导出 4 个 endpoint（v1/v2/v3/getAllGift）—— 都是 POST，但实际生产用的是 **v3**（`stores/modules/gift.js:157` 调用点）；v1 后端已下线，POST 会返 404。**同理 method**：H5 `api/live/wishlist.ts` 声明 `http.get`，iOS 侧 stage 2 我假设"iOS 后端网关兼容 method"用 POST 试真机 → 后端明码 `Maybe it's GET` 报错。

**成本**：stage 2 → stage 3 反悔一次（补 APIClient GET/DELETE + Service 层 3 处 method 迁移）。

## How to apply

**iOS 侧新接口接入时**：

- [ ] 找 API endpoint 时**不信任 `api/*/index.ts` 的第一个导出**——追 `stores/modules/*` 或 view 内 `.then` 实际调用点确认版本 + method
- [ ] endpoint 是 `http.get(...)` → APIClient 用 `.get(path, query:)`；query 参数走 URL query string
- [ ] endpoint 是 `http.delete(...)` → APIClient 用 `.delete(path)`；id 走 URL path
- [ ] endpoint 是 `http.post(...)` → APIClient 用 `.post(path, body:)`；body dict/array 版本都有
- [ ] 真机看到 `code=1111` / `parameter.error` / `method not allowed` → **优先怀疑 method 错**，再改 body/params

## 与既有规则关联

- [ios-decode-userid-compat.md](ios-decode-userid-compat.md)：同源精神——"H5 `type.ts` 类型声明不可信，追真机响应"；本 rule 补"H5 `api/*/index.ts` method/endpoint 声明不可信，追 store 层调用点"
