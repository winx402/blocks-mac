# 002_剪贴板持久化

状态：implemented-v0
最后审阅：2026-07-05
来源级别：project control

本项目承接 App 数据存储架构规范和剪贴板内容持久化首个落地场景。当前阶段先建立统一存储边界，再把剪贴板历史、payload、检索、策略裁剪和验收接入生产级 repository。

## 当前文档

- [App 数据存储架构规范 v0](数据存储架构规范-v0.md)：全 App 数据分类、SQLite / sidecar / Keychain / UserDefaults 分层和 repository 边界。
- [剪贴板持久化存储方案 v0](剪贴板持久化存储方案-v0.md)：按统一数据架构落地剪贴板生产持久化。
- [2026-07-05 架构与剪贴板持久化实施记录](2026-07-05-架构与剪贴板持久化实施记录.md)：记录子 agent 分工、实施过程和验收状态。

## 项目目标

- 明确 App 内数据存储统一规范，不让业务历史散落在内存态、UserDefaults 或 JSON debug store。
- 定义 `AppDatabase`、`SQLiteConnection`、`MigrationRunner`、`BlobStore`、domain repository 的基础边界。
- 定义 `ClipboardRepository`、SQLite schema、sidecar payload、检索、裁剪和删除一致性边界，作为首个落地场景。
- 保持 agent、日志、helper stdout 和 provider audit 默认只接触 redacted summary。
- 子 agent 可承接开发、测试和审查；主 agent 负责方向、范围、产出和最终验收。

## 目录规则

- 当前项目暂不拆阶段，文档直接平铺在本目录。
- 如果后续拆成多阶段实施，在本目录新增 `step.md` 作为阶段总览，并按需创建 `step_1/`、`step_2/` 等阶段目录。
- 子 agent 的调研、执行回报、评审意见和验收记录应进入本项目目录；属于某个阶段时放入对应阶段目录。

## 关联入口

- [项目管理库](../index.md)
- [技术知识库](../../技术知识库/index.md)
