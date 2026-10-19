/**
 * DynamicIsland Native SDK 1.0.0 release candidate; not publicly released.
 *
 * This file describes a deliberately small javascriptcore surface exercised by
 * the official Pomodoro and GitHub examples. It is not a declaration of
 * the complete Host implementation. Runtime validation,
 * package capabilities, explicit permissions, quotas and lifecycle admission
 * remain authoritative. No browser, Node.js or SuperIsland globals are added.
 */
export {};

// Private type brands are not runtime values or public token constructors.
declare const userActivationBrand: unique symbol;
declare const countdownGenerationBrand: unique symbol;

declare global {
    namespace DynamicIsland {
        /** Hooks must return undefined synchronously, never a Promise. */
        type LifecycleHook = () => undefined;
        interface LifecycleContract {
            readonly onStart: LifecycleHook;
            readonly onStop: LifecycleHook;
        }

        type LogLevel = 'debug' | 'info' | 'warning' | 'error';
        type SemanticColor = 'primary' | 'secondary' | 'accent' | 'success' | 'warning' | 'danger';
        type ProgressStyle = 'linear' | 'battery';
        type CountdownStyle = 'time' | 'progress';
        type Priority = 'background' | 'normal';
        type LifecyclePolicy = 'transient' | 'persistent' | 'progress';

        /**
         * Outgoing plain JSON data. Dense arrays, finite numbers, own data
         * properties and bounded depth/size are checked again by the Host.
         * Accessors, functions, cycles, sparse arrays and undefined are invalid.
         */
        type JSONValue = null | boolean | number | string | readonly JSONValue[] | JSONObject;
        interface JSONObject { readonly [key: string]: JSONValue; }

        /**
         * Incoming arrays have a null prototype. Only length and numeric
         * indexing are promised: no map/slice/every, iterator or array spread.
         * Array.isArray is true at runtime but TypeScript's built-in narrowing
         * to any[] must not be used as evidence that prototype methods exist.
         */
        interface HostJSONArray {
            readonly length: number;
            readonly [index: number]: HostJSONValue;
        }
        interface HostJSONObject { readonly [key: string]: HostJSONValue; }
        type HostJSONValue = null | boolean | number | string | HostJSONArray | HostJSONObject;

        /** Host rejections are data objects, not necessarily Error instances. */
        interface BridgeError {
            readonly code: string;
            readonly message: string;
        }

        /**
         * A Host-issued, short-lived, single-use user-action ticket. It may be
         * absent. Narrow event.activation before use; never persist, fabricate
         * or reuse it after another action. Types cannot extend its lifetime.
         */
        type UserActivation = string & { readonly [userActivationBrand]: never };
        /** Obtain this opaque identity from the current Host countdown record. */
        type CountdownGeneration = string & { readonly [countdownGenerationBrand]: never };

        /** Finite SDK node subset; dimensions, custom fonts and CSS are absent. */
        type Node = TextNode | IconNode | StackNode | SpacerNode | ProgressNode | CountdownNode | ButtonNode;
        interface TextNode {
            readonly type: 'text';
            /** At most 256 UTF-8 bytes. */
            readonly content: string;
            readonly color?: SemanticColor;
        }
        interface IconNode {
            readonly type: 'icon';
            /** SF Symbol identifier, not an image path or URL. */
            readonly symbolName: string;
        }
        interface StackNode {
            readonly type: 'hStack' | 'vStack';
            readonly children: readonly Node[];
        }
        interface SpacerNode { readonly type: 'spacer'; }
        interface ProgressNode {
            readonly type: 'progress';
            /** Finite normalized value in 0...1; this is not a percentage. */
            readonly value: number;
            readonly style?: ProgressStyle;
            readonly color?: SemanticColor;
        }
        interface CountdownNode {
            readonly type: 'countdown';
            readonly id: string;
            readonly generation: CountdownGeneration;
            readonly style?: CountdownStyle;
            readonly color?: SemanticColor;
        }
        interface ButtonNode {
            readonly type: 'button';
            /** Must also be declared in the owning Activity's actions. */
            readonly actionID: string;
            readonly label: Node;
            readonly accessibilityLabel?: string;
        }

        interface PresentationFields {
            /** Nonblank, at most 256 UTF-8 bytes. */
            readonly title: string;
            readonly subtitle?: string;
            readonly symbolName?: string;
            readonly progress?: number;
            readonly minimal?: Node;
            readonly compact?: Node;
            readonly expanded?: Node;
            readonly showsCompact?: boolean;
        }
        type Presentation = PresentationFields & (
            | { readonly role: 'tool'; readonly compactPolicy?: 'selectedOnly' | 'automatic' }
            | { readonly role?: 'status'; readonly compactPolicy?: never }
        );
        interface ActivityAction {
            readonly id: string;
            readonly title: string;
        }
        interface ActivityChanges {
            readonly priority: Priority;
            readonly lifecycle: { readonly policy: LifecyclePolicy };
            /** A replacement presentation, not a nested partial patch. */
            readonly presentation: Presentation;
            readonly actions: readonly ActivityAction[];
        }
        interface ActivityPublish {
            /** Local identifier: 1...80 ASCII letters, digits, dot, dash or underscore. */
            readonly id: string;
            readonly presentation: Presentation;
            readonly priority?: Priority;
            /** Defaults to transient. Tools require persistent or progress. */
            readonly lifecycle?: { readonly policy: LifecyclePolicy };
            /** At most eight unique declarations. Register handlers before publishing. */
            readonly actions?: readonly ActivityAction[];
        }
        type AtLeastOne<T> = { [K in keyof T]-?: Pick<T, K> & Partial<Omit<T, K>> }[keyof T];
        /** At least one patch field is required; lifecycle policy cannot change. */
        type ActivityUpdate = { readonly id: string } & AtLeastOne<ActivityChanges>;
        interface ActivityReceipt { readonly id: string; }
        interface ActivityAPI {
            readonly apiVersion: '1.0.0';
            readonly publish: (request: ActivityPublish) => Promise<ActivityReceipt>;
            readonly update: (request: ActivityUpdate) => Promise<ActivityReceipt>;
            readonly end: (id: string) => Promise<null>;
        }

        type ActionValue =
            | { readonly type: 'none' }
            | { readonly type: 'toggle'; readonly value: boolean }
            | { readonly type: 'slider' | 'sliderCommit'; readonly value: number };
        interface ActionEvent {
            readonly activityID: string;
            readonly actionID: string;
            readonly value: ActionValue;
            readonly activation?: UserActivation;
        }
        /** Action and completion handlers may return a genuine Promise. */
        type ActionHandler = (event: ActionEvent) => void | Promise<unknown>;
        interface ActionsAPI {
            readonly apiVersion: '1.0.0';
            readonly supported: true;
            readonly on: (actionID: string, handler: ActionHandler) => Promise<null>;
        }
        interface StorageAPI {
            readonly apiVersion: '1.0.0';
            /** Requires storage.local capability and explicitly granted permission. */
            readonly get: (key: string) => Promise<HostJSONValue>;
            readonly set: (key: string, value: JSONValue) => Promise<null>;
        }
        type SchedulerPolicy = 'active' | 'background' | 'lowPower';
        interface RefreshReceipt { readonly policy: SchedulerPolicy; }
        interface SchedulerAPI {
            readonly apiVersion: '1.0.0';
            readonly supported: true;
            /**
             * A one-shot request; resolves when the Host admits the refresh,
             * not immediately at scheduling time. Delay is an integer in
             * 1000...86400000 ms. Host policy can increase/coalesce the delay.
             * One pending request per execution; no JavaScript interval timer.
             */
            readonly requestRefresh: (delayMs: number) => Promise<RefreshReceipt>;
        }
        interface CountdownSnapshot {
            readonly id: string;
            readonly generation: CountdownGeneration;
            readonly state: 'running' | 'paused' | 'completed';
            readonly durationMs: number;
            readonly remainingMs: number;
        }
        interface CountdownCompletion extends CountdownSnapshot {
            readonly state: 'completed';
            readonly remainingMs: 0;
        }
        interface CountdownReference {
            readonly id: string;
            readonly generation: CountdownGeneration;
        }
        interface CountdownAPI {
            readonly apiVersion: '1.0.0';
            readonly supported: true;
            readonly get: (id: string) => Promise<CountdownSnapshot | null>;
            /** Requires a fresh Host activation and integer duration 1000...86400000 ms. */
            readonly start: (options: {
                readonly id: string; readonly durationMs: number; readonly activation: UserActivation;
            }) => Promise<CountdownSnapshot>;
            readonly pause: (options: CountdownReference) => Promise<CountdownSnapshot>;
            readonly resume: (options: CountdownReference & { readonly activation: UserActivation }) => Promise<CountdownSnapshot>;
            readonly stop: (options: CountdownReference) => Promise<null>;
            /** One current handler; a successful registration replaces its predecessor. */
            readonly onComplete: (handler: (event: CountdownCompletion) => void | Promise<unknown>) => Promise<null>;
        }
        interface NetworkOptions {
            readonly method?: 'GET' | 'HEAD';
            readonly headers?: Readonly<Record<string, string>>;
            /** Integer 100...30000 ms; Host request and response bounds still apply. */
            readonly timeoutMs?: number;
        }
        interface NetworkResponse {
            readonly status: number;
            readonly ok: boolean;
            /** Null-prototype data record; use own keys, not inherited methods. */
            readonly headers: Readonly<Record<string, string>>;
            readonly text: () => Promise<string>;
            /** Validates JSON but does not validate an application's domain schema. */
            readonly json: () => Promise<HostJSONValue>;
        }
        interface NetworkAPI {
            readonly apiVersion: '1.0.0';
            readonly supported: true;
            /** HTTPS GET/HEAD only, subject to network permission and Host destination policy. */
            readonly fetch: (url: string, options?: NetworkOptions) => Promise<NetworkResponse>;
        }
        interface LinksAPI {
            readonly apiVersion: '1.0.0';
            readonly supported: true;
            /**
             * Requires links.open capability and permission plus a fresh
             * activation from an eligible action. HTTPS targets are checked
             * by the Host allowlist; support does not imply authorization.
             */
            readonly open: (options: { readonly url: string; readonly activation: UserActivation }) => Promise<null>;
        }
        interface API {
            readonly apiVersion: '1.0.0';
            readonly plugin: { readonly id: string; readonly name: string; readonly version: string };
            /** Message text is omitted from retained Host diagnostic records. */
            readonly log: (message: string, level?: LogLevel) => Promise<null>;
            readonly activity: ActivityAPI;
            readonly actions: ActionsAPI;
            readonly storage: StorageAPI;
            readonly scheduler: SchedulerAPI;
            readonly countdown: CountdownAPI;
            readonly network: NetworkAPI;
            readonly links: LinksAPI;
        }
    }

    const island: DynamicIsland.API;
}
