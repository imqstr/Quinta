import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
type Driver = { request(command: string, args?: Record<string, unknown>): Promise<unknown>; listen?(name: string, callback: (payload: unknown) => void): Promise<() => void> };
declare global { interface Window { __QUINTA_TEST_BRIDGE__?: Driver } }
const driver = import.meta.env.MODE === 'development' ? window.__QUINTA_TEST_BRIDGE__ : undefined;
export async function request<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  return (driver ? driver.request(command, args) : invoke(command, args)) as Promise<T>;
}
export async function onEvent<T>(name: string, callback: (payload: T) => void): Promise<() => void> {
  if (driver?.listen) return driver.listen(name, payload => callback(payload as T));
  return listen<T>(name, event => callback(event.payload));
}
