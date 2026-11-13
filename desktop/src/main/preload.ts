// The only door between the screens and the rest of the app: named requests and updates.
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("wolf", {
  call: (name: string, ...args: any[]) => ipcRenderer.invoke("wolf", name, ...args),
  on: (channel: string, listener: (payload: any) => void) => {
    const wrapped = (_event: unknown, payload: any) => listener(payload);
    ipcRenderer.on(`wolf:${channel}`, wrapped);
    return () => ipcRenderer.removeListener(`wolf:${channel}`, wrapped);
  },
});
