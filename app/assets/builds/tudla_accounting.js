/* TudlaAccounting's pages, built by rake tudla_accounting:js:build from app/javascript/tudla_accounting. Don't edit.
   Includes Stimulus (from stimulus-rails 1.3.4), MIT License, Copyright (c) Basecamp, LLC. */
(() => {
"use strict";
const { Application, Controller } = (() => {
//= link ./stimulus-autoloader.js
//= link ./stimulus-importmap-autoloader.js
//= link ./stimulus-loading.js
class e{constructor(e,t,s){this.eventTarget=e,this.eventName=t,this.eventOptions=s,this.unorderedBindings=new Set}connect(){this.eventTarget.addEventListener(this.eventName,this,this.eventOptions)}disconnect(){this.eventTarget.removeEventListener(this.eventName,this,this.eventOptions)}bindingConnected(e){this.unorderedBindings.add(e)}bindingDisconnected(e){this.unorderedBindings.delete(e)}handleEvent(e){const t=function(e){if("immediatePropagationStopped"in e)return e;{const{stopImmediatePropagation:t}=e;return Object.assign(e,{immediatePropagationStopped:!1,stopImmediatePropagation(){this.immediatePropagationStopped=!0,t.call(this)}})}}(e);for(const e of this.bindings){if(t.immediatePropagationStopped)break;e.handleEvent(t)}}hasBindings(){return this.unorderedBindings.size>0}get bindings(){return Array.from(this.unorderedBindings).sort(((e,t)=>{const s=e.index,r=t.index;return s<r?-1:s>r?1:0}))}}class t{constructor(e){this.application=e,this.eventListenerMaps=new Map,this.started=!1}start(){this.started||(this.started=!0,this.eventListeners.forEach((e=>e.connect())))}stop(){this.started&&(this.started=!1,this.eventListeners.forEach((e=>e.disconnect())))}get eventListeners(){return Array.from(this.eventListenerMaps.values()).reduce(((e,t)=>e.concat(Array.from(t.values()))),[])}bindingConnected(e){this.fetchEventListenerForBinding(e).bindingConnected(e)}bindingDisconnected(e,t=!1){this.fetchEventListenerForBinding(e).bindingDisconnected(e),t&&this.clearEventListenersForBinding(e)}handleError(e,t,s={}){this.application.handleError(e,`Error ${t}`,s)}clearEventListenersForBinding(e){const t=this.fetchEventListenerForBinding(e);t.hasBindings()||(t.disconnect(),this.removeMappedEventListenerFor(e))}removeMappedEventListenerFor(e){const{eventTarget:t,eventName:s,eventOptions:r}=e,n=this.fetchEventListenerMapForEventTarget(t),i=this.cacheKey(s,r);n.delete(i),0==n.size&&this.eventListenerMaps.delete(t)}fetchEventListenerForBinding(e){const{eventTarget:t,eventName:s,eventOptions:r}=e;return this.fetchEventListener(t,s,r)}fetchEventListener(e,t,s){const r=this.fetchEventListenerMapForEventTarget(e),n=this.cacheKey(t,s);let i=r.get(n);return i||(i=this.createEventListener(e,t,s),r.set(n,i)),i}createEventListener(t,s,r){const n=new e(t,s,r);return this.started&&n.connect(),n}fetchEventListenerMapForEventTarget(e){let t=this.eventListenerMaps.get(e);return t||(t=new Map,this.eventListenerMaps.set(e,t)),t}cacheKey(e,t){const s=[e];return Object.keys(t).sort().forEach((e=>{s.push(`${t[e]?"":"!"}${e}`)})),s.join(":")}}const s={stop:({event:e,value:t})=>(t&&e.stopPropagation(),!0),prevent:({event:e,value:t})=>(t&&e.preventDefault(),!0),self:({event:e,value:t,element:s})=>!t||s===e.target},r=/^(?:(?:([^.]+?)\+)?(.+?)(?:\.(.+?))?(?:@(window|document))?->)?(.+?)(?:#([^:]+?))(?::(.+))?$/;function n(e){return"window"==e?window:"document"==e?document:void 0}function i(e){return e.replace(/(?:[_-])([a-z0-9])/g,((e,t)=>t.toUpperCase()))}function o(e){return i(e.replace(/--/g,"-").replace(/__/g,"_"))}function a(e){return e.charAt(0).toUpperCase()+e.slice(1)}function c(e){return e.replace(/([A-Z])/g,((e,t)=>`-${t.toLowerCase()}`))}function l(e){return null!=e}function h(e,t){return Object.prototype.hasOwnProperty.call(e,t)}const u=["meta","ctrl","alt","shift"];const d={a:()=>"click",button:()=>"click",form:()=>"submit",details:()=>"toggle",input:e=>"submit"==e.getAttribute("type")?"click":"input",select:()=>"change",textarea:()=>"input"};function m(e){throw new Error(e)}function g(e){try{return JSON.parse(e)}catch(t){return e}}class p{constructor(e,t){this.context=e,this.action=t}get index(){return this.action.index}get eventTarget(){return this.action.eventTarget}get eventOptions(){return this.action.eventOptions}get identifier(){return this.context.identifier}handleEvent(e){const t=this.prepareActionEvent(e);this.willBeInvokedByEvent(e)&&this.applyEventModifiers(t)&&this.invokeWithEvent(t)}get eventName(){return this.action.eventName}get method(){const e=this.controller[this.methodName];if("function"==typeof e)return e;throw new Error(`Action "${this.action}" references undefined method "${this.methodName}"`)}applyEventModifiers(e){const{element:t}=this.action,{actionDescriptorFilters:s}=this.context.application,{controller:r}=this.context;let n=!0;for(const[i,o]of Object.entries(this.eventOptions))if(i in s){const a=s[i];n=n&&a({name:i,value:o,event:e,element:t,controller:r})}return n}prepareActionEvent(e){return Object.assign(e,{params:this.action.params})}invokeWithEvent(e){const{target:t,currentTarget:s}=e;try{this.method.call(this.controller,e),this.context.logDebugActivity(this.methodName,{event:e,target:t,currentTarget:s,action:this.methodName})}catch(t){const{identifier:s,controller:r,element:n,index:i}=this,o={identifier:s,controller:r,element:n,index:i,event:e};this.context.handleError(t,`invoking action "${this.action}"`,o)}}willBeInvokedByEvent(e){const t=e.target;return!(e instanceof KeyboardEvent&&this.action.shouldIgnoreKeyboardEvent(e))&&(!(e instanceof MouseEvent&&this.action.shouldIgnoreMouseEvent(e))&&(this.element===t||(t instanceof Element&&this.element.contains(t)?this.scope.containsElement(t):this.scope.containsElement(this.action.element))))}get controller(){return this.context.controller}get methodName(){return this.action.methodName}get element(){return this.scope.element}get scope(){return this.context.scope}}class f{constructor(e,t){this.mutationObserverInit={attributes:!0,childList:!0,subtree:!0},this.element=e,this.started=!1,this.delegate=t,this.elements=new Set,this.mutationObserver=new MutationObserver((e=>this.processMutations(e)))}start(){this.started||(this.started=!0,this.mutationObserver.observe(this.element,this.mutationObserverInit),this.refresh())}pause(e){this.started&&(this.mutationObserver.disconnect(),this.started=!1),e(),this.started||(this.mutationObserver.observe(this.element,this.mutationObserverInit),this.started=!0)}stop(){this.started&&(this.mutationObserver.takeRecords(),this.mutationObserver.disconnect(),this.started=!1)}refresh(){if(this.started){const e=new Set(this.matchElementsInTree());for(const t of Array.from(this.elements))e.has(t)||this.removeElement(t);for(const t of Array.from(e))this.addElement(t)}}processMutations(e){if(this.started)for(const t of e)this.processMutation(t)}processMutation(e){"attributes"==e.type?this.processAttributeChange(e.target,e.attributeName):"childList"==e.type&&(this.processRemovedNodes(e.removedNodes),this.processAddedNodes(e.addedNodes))}processAttributeChange(e,t){this.elements.has(e)?this.delegate.elementAttributeChanged&&this.matchElement(e)?this.delegate.elementAttributeChanged(e,t):this.removeElement(e):this.matchElement(e)&&this.addElement(e)}processRemovedNodes(e){for(const t of Array.from(e)){const e=this.elementFromNode(t);e&&this.processTree(e,this.removeElement)}}processAddedNodes(e){for(const t of Array.from(e)){const e=this.elementFromNode(t);e&&this.elementIsActive(e)&&this.processTree(e,this.addElement)}}matchElement(e){return this.delegate.matchElement(e)}matchElementsInTree(e=this.element){return this.delegate.matchElementsInTree(e)}processTree(e,t){for(const s of this.matchElementsInTree(e))t.call(this,s)}elementFromNode(e){if(e.nodeType==Node.ELEMENT_NODE)return e}elementIsActive(e){return e.isConnected==this.element.isConnected&&this.element.contains(e)}addElement(e){this.elements.has(e)||this.elementIsActive(e)&&(this.elements.add(e),this.delegate.elementMatched&&this.delegate.elementMatched(e))}removeElement(e){this.elements.has(e)&&(this.elements.delete(e),this.delegate.elementUnmatched&&this.delegate.elementUnmatched(e))}}class b{constructor(e,t,s){this.attributeName=t,this.delegate=s,this.elementObserver=new f(e,this)}get element(){return this.elementObserver.element}get selector(){return`[${this.attributeName}]`}start(){this.elementObserver.start()}pause(e){this.elementObserver.pause(e)}stop(){this.elementObserver.stop()}refresh(){this.elementObserver.refresh()}get started(){return this.elementObserver.started}matchElement(e){return e.hasAttribute(this.attributeName)}matchElementsInTree(e){const t=this.matchElement(e)?[e]:[],s=Array.from(e.querySelectorAll(this.selector));return t.concat(s)}elementMatched(e){this.delegate.elementMatchedAttribute&&this.delegate.elementMatchedAttribute(e,this.attributeName)}elementUnmatched(e){this.delegate.elementUnmatchedAttribute&&this.delegate.elementUnmatchedAttribute(e,this.attributeName)}elementAttributeChanged(e,t){this.delegate.elementAttributeValueChanged&&this.attributeName==t&&this.delegate.elementAttributeValueChanged(e,t)}}function v(e,t,s){O(e,t).add(s)}function y(e,t,s){O(e,t).delete(s),A(e,t)}function O(e,t){let s=e.get(t);return s||(s=new Set,e.set(t,s)),s}function A(e,t){const s=e.get(t);null!=s&&0==s.size&&e.delete(t)}class E{constructor(){this.valuesByKey=new Map}get keys(){return Array.from(this.valuesByKey.keys())}get values(){return Array.from(this.valuesByKey.values()).reduce(((e,t)=>e.concat(Array.from(t))),[])}get size(){return Array.from(this.valuesByKey.values()).reduce(((e,t)=>e+t.size),0)}add(e,t){v(this.valuesByKey,e,t)}delete(e,t){y(this.valuesByKey,e,t)}has(e,t){const s=this.valuesByKey.get(e);return null!=s&&s.has(t)}hasKey(e){return this.valuesByKey.has(e)}hasValue(e){return Array.from(this.valuesByKey.values()).some((t=>t.has(e)))}getValuesForKey(e){const t=this.valuesByKey.get(e);return t?Array.from(t):[]}getKeysForValue(e){return Array.from(this.valuesByKey).filter((([t,s])=>s.has(e))).map((([e,t])=>e))}}class w extends E{constructor(){super(),this.keysByValue=new Map}get values(){return Array.from(this.keysByValue.keys())}add(e,t){super.add(e,t),v(this.keysByValue,t,e)}delete(e,t){super.delete(e,t),y(this.keysByValue,t,e)}hasValue(e){return this.keysByValue.has(e)}getKeysForValue(e){const t=this.keysByValue.get(e);return t?Array.from(t):[]}}class M{constructor(e,t,s,r){this._selector=t,this.details=r,this.elementObserver=new f(e,this),this.delegate=s,this.matchesByElement=new E}get started(){return this.elementObserver.started}get selector(){return this._selector}set selector(e){this._selector=e,this.refresh()}start(){this.elementObserver.start()}pause(e){this.elementObserver.pause(e)}stop(){this.elementObserver.stop()}refresh(){this.elementObserver.refresh()}get element(){return this.elementObserver.element}matchElement(e){const{selector:t}=this;if(t){const s=e.matches(t);return this.delegate.selectorMatchElement?s&&this.delegate.selectorMatchElement(e,this.details):s}return!1}matchElementsInTree(e){const{selector:t}=this;if(t){const s=this.matchElement(e)?[e]:[],r=Array.from(e.querySelectorAll(t)).filter((e=>this.matchElement(e)));return s.concat(r)}return[]}elementMatched(e){const{selector:t}=this;t&&this.selectorMatched(e,t)}elementUnmatched(e){const t=this.matchesByElement.getKeysForValue(e);for(const s of t)this.selectorUnmatched(e,s)}elementAttributeChanged(e,t){const{selector:s}=this;if(s){const t=this.matchElement(e),r=this.matchesByElement.has(s,e);t&&!r?this.selectorMatched(e,s):!t&&r&&this.selectorUnmatched(e,s)}}selectorMatched(e,t){this.delegate.selectorMatched(e,t,this.details),this.matchesByElement.add(t,e)}selectorUnmatched(e,t){this.delegate.selectorUnmatched(e,t,this.details),this.matchesByElement.delete(t,e)}}class k{constructor(e,t){this.element=e,this.delegate=t,this.started=!1,this.stringMap=new Map,this.mutationObserver=new MutationObserver((e=>this.processMutations(e)))}start(){this.started||(this.started=!0,this.mutationObserver.observe(this.element,{attributes:!0,attributeOldValue:!0}),this.refresh())}stop(){this.started&&(this.mutationObserver.takeRecords(),this.mutationObserver.disconnect(),this.started=!1)}refresh(){if(this.started)for(const e of this.knownAttributeNames)this.refreshAttribute(e,null)}processMutations(e){if(this.started)for(const t of e)this.processMutation(t)}processMutation(e){const t=e.attributeName;t&&this.refreshAttribute(t,e.oldValue)}refreshAttribute(e,t){const s=this.delegate.getStringMapKeyForAttribute(e);if(null!=s){this.stringMap.has(e)||this.stringMapKeyAdded(s,e);const r=this.element.getAttribute(e);if(this.stringMap.get(e)!=r&&this.stringMapValueChanged(r,s,t),null==r){const t=this.stringMap.get(e);this.stringMap.delete(e),t&&this.stringMapKeyRemoved(s,e,t)}else this.stringMap.set(e,r)}}stringMapKeyAdded(e,t){this.delegate.stringMapKeyAdded&&this.delegate.stringMapKeyAdded(e,t)}stringMapValueChanged(e,t,s){this.delegate.stringMapValueChanged&&this.delegate.stringMapValueChanged(e,t,s)}stringMapKeyRemoved(e,t,s){this.delegate.stringMapKeyRemoved&&this.delegate.stringMapKeyRemoved(e,t,s)}get knownAttributeNames(){return Array.from(new Set(this.currentAttributeNames.concat(this.recordedAttributeNames)))}get currentAttributeNames(){return Array.from(this.element.attributes).map((e=>e.name))}get recordedAttributeNames(){return Array.from(this.stringMap.keys())}}class N{constructor(e,t,s){this.attributeObserver=new b(e,t,this),this.delegate=s,this.tokensByElement=new E}get started(){return this.attributeObserver.started}start(){this.attributeObserver.start()}pause(e){this.attributeObserver.pause(e)}stop(){this.attributeObserver.stop()}refresh(){this.attributeObserver.refresh()}get element(){return this.attributeObserver.element}get attributeName(){return this.attributeObserver.attributeName}elementMatchedAttribute(e){this.tokensMatched(this.readTokensForElement(e))}elementAttributeValueChanged(e){const[t,s]=this.refreshTokensForElement(e);this.tokensUnmatched(t),this.tokensMatched(s)}elementUnmatchedAttribute(e){this.tokensUnmatched(this.tokensByElement.getValuesForKey(e))}tokensMatched(e){e.forEach((e=>this.tokenMatched(e)))}tokensUnmatched(e){e.forEach((e=>this.tokenUnmatched(e)))}tokenMatched(e){this.delegate.tokenMatched(e),this.tokensByElement.add(e.element,e)}tokenUnmatched(e){this.delegate.tokenUnmatched(e),this.tokensByElement.delete(e.element,e)}refreshTokensForElement(e){const t=this.tokensByElement.getValuesForKey(e),s=this.readTokensForElement(e),r=function(e,t){const s=Math.max(e.length,t.length);return Array.from({length:s},((s,r)=>[e[r],t[r]]))}(t,s).findIndex((([e,t])=>{return r=t,!((s=e)&&r&&s.index==r.index&&s.content==r.content);var s,r}));return-1==r?[[],[]]:[t.slice(r),s.slice(r)]}readTokensForElement(e){const t=this.attributeName;return function(e,t,s){return e.trim().split(/\s+/).filter((e=>e.length)).map(((e,r)=>({element:t,attributeName:s,content:e,index:r})))}(e.getAttribute(t)||"",e,t)}}class F{constructor(e,t,s){this.tokenListObserver=new N(e,t,this),this.delegate=s,this.parseResultsByToken=new WeakMap,this.valuesByTokenByElement=new WeakMap}get started(){return this.tokenListObserver.started}start(){this.tokenListObserver.start()}stop(){this.tokenListObserver.stop()}refresh(){this.tokenListObserver.refresh()}get element(){return this.tokenListObserver.element}get attributeName(){return this.tokenListObserver.attributeName}tokenMatched(e){const{element:t}=e,{value:s}=this.fetchParseResultForToken(e);s&&(this.fetchValuesByTokenForElement(t).set(e,s),this.delegate.elementMatchedValue(t,s))}tokenUnmatched(e){const{element:t}=e,{value:s}=this.fetchParseResultForToken(e);s&&(this.fetchValuesByTokenForElement(t).delete(e),this.delegate.elementUnmatchedValue(t,s))}fetchParseResultForToken(e){let t=this.parseResultsByToken.get(e);return t||(t=this.parseToken(e),this.parseResultsByToken.set(e,t)),t}fetchValuesByTokenForElement(e){let t=this.valuesByTokenByElement.get(e);return t||(t=new Map,this.valuesByTokenByElement.set(e,t)),t}parseToken(e){try{return{value:this.delegate.parseValueForToken(e)}}catch(e){return{error:e}}}}class B{constructor(e,t){this.context=e,this.delegate=t,this.bindingsByAction=new Map}start(){this.valueListObserver||(this.valueListObserver=new F(this.element,this.actionAttribute,this),this.valueListObserver.start())}stop(){this.valueListObserver&&(this.valueListObserver.stop(),delete this.valueListObserver,this.disconnectAllActions())}get element(){return this.context.element}get identifier(){return this.context.identifier}get actionAttribute(){return this.schema.actionAttribute}get schema(){return this.context.schema}get bindings(){return Array.from(this.bindingsByAction.values())}connectAction(e){const t=new p(this.context,e);this.bindingsByAction.set(e,t),this.delegate.bindingConnected(t)}disconnectAction(e){const t=this.bindingsByAction.get(e);t&&(this.bindingsByAction.delete(e),this.delegate.bindingDisconnected(t))}disconnectAllActions(){this.bindings.forEach((e=>this.delegate.bindingDisconnected(e,!0))),this.bindingsByAction.clear()}parseValueForToken(e){const t=class{constructor(e,t,s,r){this.element=e,this.index=t,this.eventTarget=s.eventTarget||e,this.eventName=s.eventName||function(e){const t=e.tagName.toLowerCase();if(t in d)return d[t](e)}(e)||m("missing event name"),this.eventOptions=s.eventOptions||{},this.identifier=s.identifier||m("missing identifier"),this.methodName=s.methodName||m("missing method name"),this.keyFilter=s.keyFilter||"",this.schema=r}static forToken(e,t){return new this(e.element,e.index,function(e){const t=e.trim().match(r)||[];let s=t[2],i=t[3];return i&&!["keydown","keyup","keypress"].includes(s)&&(s+=`.${i}`,i=""),{eventTarget:n(t[4]),eventName:s,eventOptions:t[7]?(o=t[7],o.split(":").reduce(((e,t)=>Object.assign(e,{[t.replace(/^!/,"")]:!/^!/.test(t)})),{})):{},identifier:t[5],methodName:t[6],keyFilter:t[1]||i};var o}(e.content),t)}toString(){const e=this.keyFilter?`.${this.keyFilter}`:"",t=this.eventTargetName?`@${this.eventTargetName}`:"";return`${this.eventName}${e}${t}->${this.identifier}#${this.methodName}`}shouldIgnoreKeyboardEvent(e){if(!this.keyFilter)return!1;const t=this.keyFilter.split("+");if(this.keyFilterDissatisfied(e,t))return!0;const s=t.filter((e=>!u.includes(e)))[0];return!!s&&(h(this.keyMappings,s)||m(`contains unknown key filter: ${this.keyFilter}`),this.keyMappings[s].toLowerCase()!==e.key.toLowerCase())}shouldIgnoreMouseEvent(e){if(!this.keyFilter)return!1;const t=[this.keyFilter];return!!this.keyFilterDissatisfied(e,t)}get params(){const e={},t=new RegExp(`^data-${this.identifier}-(.+)-param$`,"i");for(const{name:s,value:r}of Array.from(this.element.attributes)){const n=s.match(t),o=n&&n[1];o&&(e[i(o)]=g(r))}return e}get eventTargetName(){return(e=this.eventTarget)==window?"window":e==document?"document":void 0;var e}get keyMappings(){return this.schema.keyMappings}keyFilterDissatisfied(e,t){const[s,r,n,i]=u.map((e=>t.includes(e)));return e.metaKey!==s||e.ctrlKey!==r||e.altKey!==n||e.shiftKey!==i}}.forToken(e,this.schema);if(t.identifier==this.identifier)return t}elementMatchedValue(e,t){this.connectAction(t)}elementUnmatchedValue(e,t){this.disconnectAction(t)}}class C{constructor(e,t){this.context=e,this.receiver=t,this.stringMapObserver=new k(this.element,this),this.valueDescriptorMap=this.controller.valueDescriptorMap}start(){this.stringMapObserver.start(),this.invokeChangedCallbacksForDefaultValues()}stop(){this.stringMapObserver.stop()}get element(){return this.context.element}get controller(){return this.context.controller}getStringMapKeyForAttribute(e){if(e in this.valueDescriptorMap)return this.valueDescriptorMap[e].name}stringMapKeyAdded(e,t){const s=this.valueDescriptorMap[t];this.hasValue(e)||this.invokeChangedCallback(e,s.writer(this.receiver[e]),s.writer(s.defaultValue))}stringMapValueChanged(e,t,s){const r=this.valueDescriptorNameMap[t];null!==e&&(null===s&&(s=r.writer(r.defaultValue)),this.invokeChangedCallback(t,e,s))}stringMapKeyRemoved(e,t,s){const r=this.valueDescriptorNameMap[e];this.hasValue(e)?this.invokeChangedCallback(e,r.writer(this.receiver[e]),s):this.invokeChangedCallback(e,r.writer(r.defaultValue),s)}invokeChangedCallbacksForDefaultValues(){for(const{key:e,name:t,defaultValue:s,writer:r}of this.valueDescriptors)null==s||this.controller.data.has(e)||this.invokeChangedCallback(t,r(s),void 0)}invokeChangedCallback(e,t,s){const r=`${e}Changed`,n=this.receiver[r];if("function"==typeof n){const r=this.valueDescriptorNameMap[e];try{const e=r.reader(t);let i=s;s&&(i=r.reader(s)),n.call(this.receiver,e,i)}catch(e){throw e instanceof TypeError&&(e.message=`Stimulus Value "${this.context.identifier}.${r.name}" - ${e.message}`),e}}}get valueDescriptors(){const{valueDescriptorMap:e}=this;return Object.keys(e).map((t=>e[t]))}get valueDescriptorNameMap(){const e={};return Object.keys(this.valueDescriptorMap).forEach((t=>{const s=this.valueDescriptorMap[t];e[s.name]=s})),e}hasValue(e){const t=`has${a(this.valueDescriptorNameMap[e].name)}`;return this.receiver[t]}}class ${constructor(e,t){this.context=e,this.delegate=t,this.targetsByName=new E}start(){this.tokenListObserver||(this.tokenListObserver=new N(this.element,this.attributeName,this),this.tokenListObserver.start())}stop(){this.tokenListObserver&&(this.disconnectAllTargets(),this.tokenListObserver.stop(),delete this.tokenListObserver)}tokenMatched({element:e,content:t}){this.scope.containsElement(e)&&this.connectTarget(e,t)}tokenUnmatched({element:e,content:t}){this.disconnectTarget(e,t)}connectTarget(e,t){var s;this.targetsByName.has(t,e)||(this.targetsByName.add(t,e),null===(s=this.tokenListObserver)||void 0===s||s.pause((()=>this.delegate.targetConnected(e,t))))}disconnectTarget(e,t){var s;this.targetsByName.has(t,e)&&(this.targetsByName.delete(t,e),null===(s=this.tokenListObserver)||void 0===s||s.pause((()=>this.delegate.targetDisconnected(e,t))))}disconnectAllTargets(){for(const e of this.targetsByName.keys)for(const t of this.targetsByName.getValuesForKey(e))this.disconnectTarget(t,e)}get attributeName(){return`data-${this.context.identifier}-target`}get element(){return this.context.element}get scope(){return this.context.scope}}function T(e,t){const s=x(e);return Array.from(s.reduce(((e,s)=>(function(e,t){const s=e[t];return Array.isArray(s)?s:[]}(s,t).forEach((t=>e.add(t))),e)),new Set))}function S(e,t){return x(e).reduce(((e,s)=>(e.push(...function(e,t){const s=e[t];return s?Object.keys(s).map((e=>[e,s[e]])):[]}(s,t)),e)),[])}function x(e){const t=[];for(;e;)t.push(e),e=Object.getPrototypeOf(e);return t.reverse()}class D{constructor(e,t){this.started=!1,this.context=e,this.delegate=t,this.outletsByName=new E,this.outletElementsByName=new E,this.selectorObserverMap=new Map,this.attributeObserverMap=new Map}start(){this.started||(this.outletDefinitions.forEach((e=>{this.setupSelectorObserverForOutlet(e),this.setupAttributeObserverForOutlet(e)})),this.started=!0,this.dependentContexts.forEach((e=>e.refresh())))}refresh(){this.selectorObserverMap.forEach((e=>e.refresh())),this.attributeObserverMap.forEach((e=>e.refresh()))}stop(){this.started&&(this.started=!1,this.disconnectAllOutlets(),this.stopSelectorObservers(),this.stopAttributeObservers())}stopSelectorObservers(){this.selectorObserverMap.size>0&&(this.selectorObserverMap.forEach((e=>e.stop())),this.selectorObserverMap.clear())}stopAttributeObservers(){this.attributeObserverMap.size>0&&(this.attributeObserverMap.forEach((e=>e.stop())),this.attributeObserverMap.clear())}selectorMatched(e,t,{outletName:s}){const r=this.getOutlet(e,s);r&&this.connectOutlet(r,e,s)}selectorUnmatched(e,t,{outletName:s}){const r=this.getOutletFromMap(e,s);r&&this.disconnectOutlet(r,e,s)}selectorMatchElement(e,{outletName:t}){const s=this.selector(t),r=this.hasOutlet(e,t),n=e.matches(`[${this.schema.controllerAttribute}~=${t}]`);return!!s&&(r&&n&&e.matches(s))}elementMatchedAttribute(e,t){const s=this.getOutletNameFromOutletAttributeName(t);s&&this.updateSelectorObserverForOutlet(s)}elementAttributeValueChanged(e,t){const s=this.getOutletNameFromOutletAttributeName(t);s&&this.updateSelectorObserverForOutlet(s)}elementUnmatchedAttribute(e,t){const s=this.getOutletNameFromOutletAttributeName(t);s&&this.updateSelectorObserverForOutlet(s)}connectOutlet(e,t,s){var r;this.outletElementsByName.has(s,t)||(this.outletsByName.add(s,e),this.outletElementsByName.add(s,t),null===(r=this.selectorObserverMap.get(s))||void 0===r||r.pause((()=>this.delegate.outletConnected(e,t,s))))}disconnectOutlet(e,t,s){var r;this.outletElementsByName.has(s,t)&&(this.outletsByName.delete(s,e),this.outletElementsByName.delete(s,t),null===(r=this.selectorObserverMap.get(s))||void 0===r||r.pause((()=>this.delegate.outletDisconnected(e,t,s))))}disconnectAllOutlets(){for(const e of this.outletElementsByName.keys)for(const t of this.outletElementsByName.getValuesForKey(e))for(const s of this.outletsByName.getValuesForKey(e))this.disconnectOutlet(s,t,e)}updateSelectorObserverForOutlet(e){const t=this.selectorObserverMap.get(e);t&&(t.selector=this.selector(e))}setupSelectorObserverForOutlet(e){const t=this.selector(e),s=new M(document.body,t,this,{outletName:e});this.selectorObserverMap.set(e,s),s.start()}setupAttributeObserverForOutlet(e){const t=this.attributeNameForOutletName(e),s=new b(this.scope.element,t,this);this.attributeObserverMap.set(e,s),s.start()}selector(e){return this.scope.outlets.getSelectorForOutletName(e)}attributeNameForOutletName(e){return this.scope.schema.outletAttributeForScope(this.identifier,e)}getOutletNameFromOutletAttributeName(e){return this.outletDefinitions.find((t=>this.attributeNameForOutletName(t)===e))}get outletDependencies(){const e=new E;return this.router.modules.forEach((t=>{T(t.definition.controllerConstructor,"outlets").forEach((s=>e.add(s,t.identifier)))})),e}get outletDefinitions(){return this.outletDependencies.getKeysForValue(this.identifier)}get dependentControllerIdentifiers(){return this.outletDependencies.getValuesForKey(this.identifier)}get dependentContexts(){const e=this.dependentControllerIdentifiers;return this.router.contexts.filter((t=>e.includes(t.identifier)))}hasOutlet(e,t){return!!this.getOutlet(e,t)||!!this.getOutletFromMap(e,t)}getOutlet(e,t){return this.application.getControllerForElementAndIdentifier(e,t)}getOutletFromMap(e,t){return this.outletsByName.getValuesForKey(t).find((t=>t.element===e))}get scope(){return this.context.scope}get schema(){return this.context.schema}get identifier(){return this.context.identifier}get application(){return this.context.application}get router(){return this.application.router}}class L{constructor(e,t){this.logDebugActivity=(e,t={})=>{const{identifier:s,controller:r,element:n}=this;t=Object.assign({identifier:s,controller:r,element:n},t),this.application.logDebugActivity(this.identifier,e,t)},this.module=e,this.scope=t,this.controller=new e.controllerConstructor(this),this.bindingObserver=new B(this,this.dispatcher),this.valueObserver=new C(this,this.controller),this.targetObserver=new $(this,this),this.outletObserver=new D(this,this);try{this.controller.initialize(),this.logDebugActivity("initialize")}catch(e){this.handleError(e,"initializing controller")}}connect(){this.bindingObserver.start(),this.valueObserver.start(),this.targetObserver.start(),this.outletObserver.start();try{this.controller.connect(),this.logDebugActivity("connect")}catch(e){this.handleError(e,"connecting controller")}}refresh(){this.outletObserver.refresh()}disconnect(){try{this.controller.disconnect(),this.logDebugActivity("disconnect")}catch(e){this.handleError(e,"disconnecting controller")}this.outletObserver.stop(),this.targetObserver.stop(),this.valueObserver.stop(),this.bindingObserver.stop()}get application(){return this.module.application}get identifier(){return this.module.identifier}get schema(){return this.application.schema}get dispatcher(){return this.application.dispatcher}get element(){return this.scope.element}get parentElement(){return this.element.parentElement}handleError(e,t,s={}){const{identifier:r,controller:n,element:i}=this;s=Object.assign({identifier:r,controller:n,element:i},s),this.application.handleError(e,`Error ${t}`,s)}targetConnected(e,t){this.invokeControllerMethod(`${t}TargetConnected`,e)}targetDisconnected(e,t){this.invokeControllerMethod(`${t}TargetDisconnected`,e)}outletConnected(e,t,s){this.invokeControllerMethod(`${o(s)}OutletConnected`,e,t)}outletDisconnected(e,t,s){this.invokeControllerMethod(`${o(s)}OutletDisconnected`,e,t)}invokeControllerMethod(e,...t){const s=this.controller;"function"==typeof s[e]&&s[e](...t)}}function V(e){return function(e,t){const s=I(e),r=function(e,t){return K(t).reduce(((s,r)=>{const n=function(e,t,s){const r=Object.getOwnPropertyDescriptor(e,s);if(!r||!("value"in r)){const e=Object.getOwnPropertyDescriptor(t,s).value;return r&&(e.get=r.get||e.get,e.set=r.set||e.set),e}}(e,t,r);return n&&Object.assign(s,{[r]:n}),s}),{})}(e.prototype,t);return Object.defineProperties(s.prototype,r),s}(e,function(e){return T(e,"blessings").reduce(((t,s)=>{const r=s(e);for(const e in r){const s=t[e]||{};t[e]=Object.assign(s,r[e])}return t}),{})}(e))}const K="function"==typeof Object.getOwnPropertySymbols?e=>[...Object.getOwnPropertyNames(e),...Object.getOwnPropertySymbols(e)]:Object.getOwnPropertyNames,I=(()=>{function e(e){function t(){return Reflect.construct(e,arguments,new.target)}return t.prototype=Object.create(e.prototype,{constructor:{value:t}}),Reflect.setPrototypeOf(t,e),t}try{return function(){const t=e((function(){this.a.call(this)}));t.prototype.a=function(){},new t}(),e}catch(e){return e=>class extends e{}}})();class j{constructor(e,t){this.application=e,this.definition=function(e){return{identifier:e.identifier,controllerConstructor:V(e.controllerConstructor)}}(t),this.contextsByScope=new WeakMap,this.connectedContexts=new Set}get identifier(){return this.definition.identifier}get controllerConstructor(){return this.definition.controllerConstructor}get contexts(){return Array.from(this.connectedContexts)}connectContextForScope(e){const t=this.fetchContextForScope(e);this.connectedContexts.add(t),t.connect()}disconnectContextForScope(e){const t=this.contextsByScope.get(e);t&&(this.connectedContexts.delete(t),t.disconnect())}fetchContextForScope(e){let t=this.contextsByScope.get(e);return t||(t=new L(this,e),this.contextsByScope.set(e,t)),t}}class U{constructor(e){this.scope=e}has(e){return this.data.has(this.getDataKey(e))}get(e){return this.getAll(e)[0]}getAll(e){const t=this.data.get(this.getDataKey(e))||"";return t.match(/[^\s]+/g)||[]}getAttributeName(e){return this.data.getAttributeNameForKey(this.getDataKey(e))}getDataKey(e){return`${e}-class`}get data(){return this.scope.data}}class P{constructor(e){this.scope=e}get element(){return this.scope.element}get identifier(){return this.scope.identifier}get(e){const t=this.getAttributeNameForKey(e);return this.element.getAttribute(t)}set(e,t){const s=this.getAttributeNameForKey(e);return this.element.setAttribute(s,t),this.get(e)}has(e){const t=this.getAttributeNameForKey(e);return this.element.hasAttribute(t)}delete(e){if(this.has(e)){const t=this.getAttributeNameForKey(e);return this.element.removeAttribute(t),!0}return!1}getAttributeNameForKey(e){return`data-${this.identifier}-${c(e)}`}}class R{constructor(e){this.warnedKeysByObject=new WeakMap,this.logger=e}warn(e,t,s){let r=this.warnedKeysByObject.get(e);r||(r=new Set,this.warnedKeysByObject.set(e,r)),r.has(t)||(r.add(t),this.logger.warn(s,e))}}function z(e,t){return`[${e}~="${t}"]`}class _{constructor(e){this.scope=e}get element(){return this.scope.element}get identifier(){return this.scope.identifier}get schema(){return this.scope.schema}has(e){return null!=this.find(e)}find(...e){return e.reduce(((e,t)=>e||this.findTarget(t)||this.findLegacyTarget(t)),void 0)}findAll(...e){return e.reduce(((e,t)=>[...e,...this.findAllTargets(t),...this.findAllLegacyTargets(t)]),[])}findTarget(e){const t=this.getSelectorForTargetName(e);return this.scope.findElement(t)}findAllTargets(e){const t=this.getSelectorForTargetName(e);return this.scope.findAllElements(t)}getSelectorForTargetName(e){return z(this.schema.targetAttributeForScope(this.identifier),e)}findLegacyTarget(e){const t=this.getLegacySelectorForTargetName(e);return this.deprecate(this.scope.findElement(t),e)}findAllLegacyTargets(e){const t=this.getLegacySelectorForTargetName(e);return this.scope.findAllElements(t).map((t=>this.deprecate(t,e)))}getLegacySelectorForTargetName(e){const t=`${this.identifier}.${e}`;return z(this.schema.targetAttribute,t)}deprecate(e,t){if(e){const{identifier:s}=this,r=this.schema.targetAttribute,n=this.schema.targetAttributeForScope(s);this.guide.warn(e,`target:${t}`,`Please replace ${r}="${s}.${t}" with ${n}="${t}". The ${r} attribute is deprecated and will be removed in a future version of Stimulus.`)}return e}get guide(){return this.scope.guide}}class q{constructor(e,t){this.scope=e,this.controllerElement=t}get element(){return this.scope.element}get identifier(){return this.scope.identifier}get schema(){return this.scope.schema}has(e){return null!=this.find(e)}find(...e){return e.reduce(((e,t)=>e||this.findOutlet(t)),void 0)}findAll(...e){return e.reduce(((e,t)=>[...e,...this.findAllOutlets(t)]),[])}getSelectorForOutletName(e){const t=this.schema.outletAttributeForScope(this.identifier,e);return this.controllerElement.getAttribute(t)}findOutlet(e){const t=this.getSelectorForOutletName(e);if(t)return this.findElement(t,e)}findAllOutlets(e){const t=this.getSelectorForOutletName(e);return t?this.findAllElements(t,e):[]}findElement(e,t){return this.scope.queryElements(e).filter((s=>this.matchesElement(s,e,t)))[0]}findAllElements(e,t){return this.scope.queryElements(e).filter((s=>this.matchesElement(s,e,t)))}matchesElement(e,t,s){const r=e.getAttribute(this.scope.schema.controllerAttribute)||"";return e.matches(t)&&r.split(" ").includes(s)}}class W{constructor(e,t,s,r){this.targets=new _(this),this.classes=new U(this),this.data=new P(this),this.containsElement=e=>e.closest(this.controllerSelector)===this.element,this.schema=e,this.element=t,this.identifier=s,this.guide=new R(r),this.outlets=new q(this.documentScope,t)}findElement(e){return this.element.matches(e)?this.element:this.queryElements(e).find(this.containsElement)}findAllElements(e){return[...this.element.matches(e)?[this.element]:[],...this.queryElements(e).filter(this.containsElement)]}queryElements(e){return Array.from(this.element.querySelectorAll(e))}get controllerSelector(){return z(this.schema.controllerAttribute,this.identifier)}get isDocumentScope(){return this.element===document.documentElement}get documentScope(){return this.isDocumentScope?this:new W(this.schema,document.documentElement,this.identifier,this.guide.logger)}}class J{constructor(e,t,s){this.element=e,this.schema=t,this.delegate=s,this.valueListObserver=new F(this.element,this.controllerAttribute,this),this.scopesByIdentifierByElement=new WeakMap,this.scopeReferenceCounts=new WeakMap}start(){this.valueListObserver.start()}stop(){this.valueListObserver.stop()}get controllerAttribute(){return this.schema.controllerAttribute}parseValueForToken(e){const{element:t,content:s}=e;return this.parseValueForElementAndIdentifier(t,s)}parseValueForElementAndIdentifier(e,t){const s=this.fetchScopesByIdentifierForElement(e);let r=s.get(t);return r||(r=this.delegate.createScopeForElementAndIdentifier(e,t),s.set(t,r)),r}elementMatchedValue(e,t){const s=(this.scopeReferenceCounts.get(t)||0)+1;this.scopeReferenceCounts.set(t,s),1==s&&this.delegate.scopeConnected(t)}elementUnmatchedValue(e,t){const s=this.scopeReferenceCounts.get(t);s&&(this.scopeReferenceCounts.set(t,s-1),1==s&&this.delegate.scopeDisconnected(t))}fetchScopesByIdentifierForElement(e){let t=this.scopesByIdentifierByElement.get(e);return t||(t=new Map,this.scopesByIdentifierByElement.set(e,t)),t}}class H{constructor(e){this.application=e,this.scopeObserver=new J(this.element,this.schema,this),this.scopesByIdentifier=new E,this.modulesByIdentifier=new Map}get element(){return this.application.element}get schema(){return this.application.schema}get logger(){return this.application.logger}get controllerAttribute(){return this.schema.controllerAttribute}get modules(){return Array.from(this.modulesByIdentifier.values())}get contexts(){return this.modules.reduce(((e,t)=>e.concat(t.contexts)),[])}start(){this.scopeObserver.start()}stop(){this.scopeObserver.stop()}loadDefinition(e){this.unloadIdentifier(e.identifier);const t=new j(this.application,e);this.connectModule(t);const s=e.controllerConstructor.afterLoad;s&&s.call(e.controllerConstructor,e.identifier,this.application)}unloadIdentifier(e){const t=this.modulesByIdentifier.get(e);t&&this.disconnectModule(t)}getContextForElementAndIdentifier(e,t){const s=this.modulesByIdentifier.get(t);if(s)return s.contexts.find((t=>t.element==e))}proposeToConnectScopeForElementAndIdentifier(e,t){const s=this.scopeObserver.parseValueForElementAndIdentifier(e,t);s?this.scopeObserver.elementMatchedValue(s.element,s):console.error(`Couldn't find or create scope for identifier: "${t}" and element:`,e)}handleError(e,t,s){this.application.handleError(e,t,s)}createScopeForElementAndIdentifier(e,t){return new W(this.schema,e,t,this.logger)}scopeConnected(e){this.scopesByIdentifier.add(e.identifier,e);const t=this.modulesByIdentifier.get(e.identifier);t&&t.connectContextForScope(e)}scopeDisconnected(e){this.scopesByIdentifier.delete(e.identifier,e);const t=this.modulesByIdentifier.get(e.identifier);t&&t.disconnectContextForScope(e)}connectModule(e){this.modulesByIdentifier.set(e.identifier,e);this.scopesByIdentifier.getValuesForKey(e.identifier).forEach((t=>e.connectContextForScope(t)))}disconnectModule(e){this.modulesByIdentifier.delete(e.identifier);this.scopesByIdentifier.getValuesForKey(e.identifier).forEach((t=>e.disconnectContextForScope(t)))}}const Z={controllerAttribute:"data-controller",actionAttribute:"data-action",targetAttribute:"data-target",targetAttributeForScope:e=>`data-${e}-target`,outletAttributeForScope:(e,t)=>`data-${e}-${t}-outlet`,keyMappings:Object.assign(Object.assign({enter:"Enter",tab:"Tab",esc:"Escape",space:" ",up:"ArrowUp",down:"ArrowDown",left:"ArrowLeft",right:"ArrowRight",home:"Home",end:"End",page_up:"PageUp",page_down:"PageDown"},G("abcdefghijklmnopqrstuvwxyz".split("").map((e=>[e,e])))),G("0123456789".split("").map((e=>[e,e]))))};function G(e){return e.reduce(((e,[t,s])=>Object.assign(Object.assign({},e),{[t]:s})),{})}class Q{constructor(e=document.documentElement,r=Z){this.logger=console,this.debug=!1,this.logDebugActivity=(e,t,s={})=>{this.debug&&this.logFormattedMessage(e,t,s)},this.element=e,this.schema=r,this.dispatcher=new t(this),this.router=new H(this),this.actionDescriptorFilters=Object.assign({},s)}static start(e,t){const s=new this(e,t);return s.start(),s}async start(){await new Promise((e=>{"loading"==document.readyState?document.addEventListener("DOMContentLoaded",(()=>e())):e()})),this.logDebugActivity("application","starting"),this.dispatcher.start(),this.router.start(),this.logDebugActivity("application","start")}stop(){this.logDebugActivity("application","stopping"),this.dispatcher.stop(),this.router.stop(),this.logDebugActivity("application","stop")}register(e,t){this.load({identifier:e,controllerConstructor:t})}registerActionOption(e,t){this.actionDescriptorFilters[e]=t}load(e,...t){(Array.isArray(e)?e:[e,...t]).forEach((e=>{e.controllerConstructor.shouldLoad&&this.router.loadDefinition(e)}))}unload(e,...t){(Array.isArray(e)?e:[e,...t]).forEach((e=>this.router.unloadIdentifier(e)))}get controllers(){return this.router.contexts.map((e=>e.controller))}getControllerForElementAndIdentifier(e,t){const s=this.router.getContextForElementAndIdentifier(e,t);return s?s.controller:null}handleError(e,t,s){var r;this.logger.error("%s\n\n%o\n\n%o",t,e,s),null===(r=window.onerror)||void 0===r||r.call(window,t,"",0,0,e)}logFormattedMessage(e,t,s={}){s=Object.assign({application:this},s),this.logger.groupCollapsed(`${e} #${t}`),this.logger.log("details:",Object.assign({},s)),this.logger.groupEnd()}}function X(e,t,s){return e.application.getControllerForElementAndIdentifier(t,s)}function Y(e,t,s){let r=X(e,t,s);return r||(e.application.router.proposeToConnectScopeForElementAndIdentifier(t,s),r=X(e,t,s),r||void 0)}function ee([e,t],s){return function(e){const{token:t,typeDefinition:s}=e,r=`${c(t)}-value`,n=function(e){const{controller:t,token:s,typeDefinition:r}=e,n=function(e){const{controller:t,token:s,typeObject:r}=e,n=l(r.type),i=l(r.default),o=n&&i,a=n&&!i,c=!n&&i,h=te(r.type),u=se(e.typeObject.default);if(a)return h;if(c)return u;if(h!==u){throw new Error(`The specified default value for the Stimulus Value "${t?`${t}.${s}`:s}" must match the defined type "${h}". The provided default value of "${r.default}" is of type "${u}".`)}if(o)return h}({controller:t,token:s,typeObject:r}),i=se(r),o=te(r),a=n||i||o;if(a)return a;throw new Error(`Unknown value type "${t?`${t}.${r}`:s}" for "${s}" value`)}(e);return{type:n,key:r,name:i(r),get defaultValue(){return function(e){const t=te(e);if(t)return re[t];const s=h(e,"default"),r=h(e,"type"),n=e;if(s)return n.default;if(r){const{type:e}=n,t=te(e);if(t)return re[t]}return e}(s)},get hasCustomDefaultValue(){return void 0!==se(s)},reader:ne[n],writer:ie[n]||ie.default}}({controller:s,token:e,typeDefinition:t})}function te(e){switch(e){case Array:return"array";case Boolean:return"boolean";case Number:return"number";case Object:return"object";case String:return"string"}}function se(e){switch(typeof e){case"boolean":return"boolean";case"number":return"number";case"string":return"string"}return Array.isArray(e)?"array":"[object Object]"===Object.prototype.toString.call(e)?"object":void 0}const re={get array(){return[]},boolean:!1,number:0,get object(){return{}},string:""},ne={array(e){const t=JSON.parse(e);if(!Array.isArray(t))throw new TypeError(`expected value of type "array" but instead got value "${e}" of type "${se(t)}"`);return t},boolean:e=>!("0"==e||"false"==String(e).toLowerCase()),number:e=>Number(e.replace(/_/g,"")),object(e){const t=JSON.parse(e);if(null===t||"object"!=typeof t||Array.isArray(t))throw new TypeError(`expected value of type "object" but instead got value "${e}" of type "${se(t)}"`);return t},string:e=>e},ie={default:function(e){return`${e}`},array:oe,object:oe};function oe(e){return JSON.stringify(e)}class ae{constructor(e){this.context=e}static get shouldLoad(){return!0}static afterLoad(e,t){}get application(){return this.context.application}get scope(){return this.context.scope}get element(){return this.scope.element}get identifier(){return this.scope.identifier}get targets(){return this.scope.targets}get outlets(){return this.scope.outlets}get classes(){return this.scope.classes}get data(){return this.scope.data}initialize(){}connect(){}disconnect(){}dispatch(e,{target:t=this.element,detail:s={},prefix:r=this.identifier,bubbles:n=!0,cancelable:i=!0}={}){const o=new CustomEvent(r?`${r}:${e}`:e,{detail:s,bubbles:n,cancelable:i});return t.dispatchEvent(o),o}}ae.blessings=[function(e){return T(e,"classes").reduce(((e,t)=>{return Object.assign(e,{[`${s=t}Class`]:{get(){const{classes:e}=this;if(e.has(s))return e.get(s);{const t=e.getAttributeName(s);throw new Error(`Missing attribute "${t}"`)}}},[`${s}Classes`]:{get(){return this.classes.getAll(s)}},[`has${a(s)}Class`]:{get(){return this.classes.has(s)}}});var s}),{})},function(e){return T(e,"targets").reduce(((e,t)=>{return Object.assign(e,{[`${s=t}Target`]:{get(){const e=this.targets.find(s);if(e)return e;throw new Error(`Missing target element "${s}" for "${this.identifier}" controller`)}},[`${s}Targets`]:{get(){return this.targets.findAll(s)}},[`has${a(s)}Target`]:{get(){return this.targets.has(s)}}});var s}),{})},function(e){const t=S(e,"values"),s={valueDescriptorMap:{get(){return t.reduce(((e,t)=>{const s=ee(t,this.identifier),r=this.data.getAttributeNameForKey(s.key);return Object.assign(e,{[r]:s})}),{})}}};return t.reduce(((e,t)=>Object.assign(e,function(e,t){const s=ee(e,t),{key:r,name:n,reader:i,writer:o}=s;return{[n]:{get(){const e=this.data.get(r);return null!==e?i(e):s.defaultValue},set(e){void 0===e?this.data.delete(r):this.data.set(r,o(e))}},[`has${a(n)}`]:{get(){return this.data.has(r)||s.hasCustomDefaultValue}}}}(t))),s)},function(e){return T(e,"outlets").reduce(((e,t)=>Object.assign(e,function(e){const t=o(e);return{[`${t}Outlet`]:{get(){const t=this.outlets.find(e),s=this.outlets.getSelectorForOutletName(e);if(t){const s=Y(this,t,e);if(s)return s;throw new Error(`The provided outlet element is missing an outlet controller "${e}" instance for host controller "${this.identifier}"`)}throw new Error(`Missing outlet element "${e}" for host controller "${this.identifier}". Stimulus couldn't find a matching outlet element using selector "${s}".`)}},[`${t}Outlets`]:{get(){const t=this.outlets.findAll(e);return t.length>0?t.map((t=>{const s=Y(this,t,e);if(s)return s;console.warn(`The provided outlet element is missing an outlet controller "${e}" instance for host controller "${this.identifier}"`,t)})).filter((e=>e)):[]}},[`${t}OutletElement`]:{get(){const t=this.outlets.find(e),s=this.outlets.getSelectorForOutletName(e);if(t)return t;throw new Error(`Missing outlet element "${e}" for host controller "${this.identifier}". Stimulus couldn't find a matching outlet element using selector "${s}".`)}},[`${t}OutletElements`]:{get(){return this.outlets.findAll(e)}},[`has${a(t)}Outlet`]:{get(){return this.outlets.has(e)}}}}(t))),{})}],ae.targets=[],ae.outlets=[],ae.values={};return { Application: Q, Controller: ae };


})();
const { parseNumber, parseUnits, formatUnits, fieldUnits } = (() => {
// Reading and showing amounts in the browser, one way for every form's live totals, as
// the server reads them (TudlaAccounting::AmountParser) in the organization's number
// format, which the layout gives: digits with its decimal mark ("." or ","), optionally
// grouped in thousands by its separator, signed by "+", "-" or parentheses. Anything else
// counts as nothing here; the server says what is wrong with it.

function marks() {
  const { tcDecimalMark: decimal = ".", tcThousandsSeparator: thousands = "," } = document.body.dataset
  return { decimal, thousands }
}

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

function pattern({ decimal, thousands }) {
  const grouped = thousands ? `\\d{1,3}(?:${escape(thousands)}\\d{3})+|` : ""
  return new RegExp(`^[+-]?(?:${grouped}\\d+)?(?:${escape(decimal)}\\d*)?$`)
}

// A typed number, or null when blank or unreadable.
function parseNumber(text) {
  const { decimal, thousands } = marks()
  let typed = String(text ?? "").trim()
  const negative = typed.startsWith("(") && typed.endsWith(")")
  if (negative) typed = typed.slice(1, -1).trim()
  if (!pattern({ decimal, thousands }).test(typed) || !/\d/.test(typed) || (negative && /^[+-]/.test(typed))) return null

  const plain = (thousands ? typed.replaceAll(thousands, "") : typed).replace(decimal, ".")
  const number = Number(plain)
  return negative ? -number : number
}

// A typed amount in minor units (cents), so totals don't pick up floating-point error;
// 0 when blank or unreadable.
function parseUnits(text, exponent) {
  const number = parseNumber(text)
  return number === null ? 0 : Math.round(number * 10 ** exponent)
}

// Minor units as the page shows amounts, in the organization's style the layout gives
// (as tc_money writes them): "1,234.50", or "1.234,50" in comma books.
function formatUnits(units, exponent) {
  const { decimal, thousands } = marks()
  const [whole, fraction] = (Math.abs(units) / 10 ** exponent).toFixed(exponent).split(".")
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, thousands)
  return `${units < 0 ? "-" : ""}${grouped}${fraction ? decimal + fraction : ""}`
}

// Minor units as a form field holds them: "1234.50", or "1234,50" in comma books (as
// tc_amount_field writes them).
function fieldUnits(units, exponent) {
  return (units / 10 ** exponent).toFixed(exponent).replace(".", marks().decimal)
}

return { parseNumber, parseUnits, formatUnits, fieldUnits };
})();
const application = Application.start();
application.register("budget-grid", (() => {

// A budget's grid: keeps each account's year total, its parents' totals, each section's
// totals and the net profit up to date as amounts are typed, and spreads a year total
// typed in evenly over the months (what doesn't divide evenly going in the last month).
// The server works the totals out again.
const controller = class extends Controller {
  static targets = ["amount", "rowTotal", "sum", "sectionTotal", "net"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.recalculate()
  }

  recalculate() {
    const rows = {}
    const sums = {}
    const sections = {}
    const add = (totals, key, month, units) => {
      totals[key] ||= {}
      totals[key][month] = (totals[key][month] || 0) + units
      totals[key].year = (totals[key].year || 0) + units
    }
    this.amountTargets.forEach((input) => {
      const units = this.parse(input.value)
      const { account, month, category, ancestors, sign } = input.dataset
      rows[account] = (rows[account] || 0) + units
      ancestors.split(" ").filter(Boolean).forEach((ancestor) => add(sums, ancestor, month, units))
      add(sections, category, month, units * Number(sign))
    })

    this.rowTotalTargets.forEach((input) => {
      if (input !== document.activeElement) input.value = rows[input.dataset.account] ? this.plain(rows[input.dataset.account]) : ""
    })
    this.sumTargets.forEach((cell) => this.show(cell, sums[cell.dataset.account]?.[cell.dataset.month] || 0))
    this.sectionTotalTargets.forEach((cell) => this.show(cell, sections[cell.dataset.category]?.[cell.dataset.month] || 0))
    this.netTargets.forEach((cell) => {
      const month = cell.dataset.month
      this.show(cell, (sections.income?.[month] || 0) - (sections.expense?.[month] || 0))
    })
  }

  spread(event) {
    const total = this.parse(event.target.value)
    const inputs = this.amountTargets.filter((input) => input.dataset.account === event.target.dataset.account)
    const each = Math.trunc(total / inputs.length)
    inputs.forEach((input, index) => {
      const units = index === inputs.length - 1 ? total - each * (inputs.length - 1) : each
      input.value = units ? this.plain(units) : ""
    })
    this.recalculate()
  }



  // An amount as the page shows amounts: separators, negatives in parentheses.
  show(cell, units) {
    const text = this.format(Math.abs(units))
    cell.innerHTML = ""
    if (units < 0) {
      const span = document.createElement("span")
      span.className = "tc-negative"
      span.textContent = `(${text})`
      cell.append(span)
    } else {
      cell.textContent = text
    }
  }

  // Amounts in the currency's minor units (see tudla_accounting/amounts).
  parse(text) { return parseUnits(text, this.exponentValue) }
  format(units) { return formatUnits(units, this.exponentValue) }
  plain(units) { return fieldUnits(units, this.exponentValue) }
}

return controller;
})());
application.register("confirm", (() => {

// Asks before submitting a destructive form, inline rather than with a browser dialog:
// the first submit turns the button into "Click again to confirm".
const controller = class extends Controller {
  static values = { message: String }

  connect() {
    this.element.dataset.confirmReady = "true" // lets browser tests wait until confirming works
  }

  ask(event) {
    if (this.element.dataset.confirmed === "true") return

    event.preventDefault()
    this.element.dataset.confirmed = "true"
    const button = this.element.querySelector("[type=submit]")
    const label = `${this.messageValue} Click again to confirm`
    if (button.tagName === "INPUT") button.value = label // <input type=submit>: its label is its value
    else button.textContent = label
    button.setAttribute("aria-live", "polite")
  }
}

return controller;
})());
application.register("dismiss", (() => {

// Removes the element, e.g. a flash message's close button: data-action="dismiss#close"
const controller = class extends Controller {
  close() {
    this.element.remove()
  }
}

return controller;
})());
application.register("document-lines", (() => {

// The invoice and bill form's lines: adds and removes them, works out each line's amount
// (quantity times unit price) and the subtotal, tax and total as they're typed, the way
// the server will (tax rounded per line, added or split out). Choosing a contact sets the
// due date from their payment terms (when the form has dates), and their default account
// tax code and withholding code on lines that have none yet. Choosing another currency asks for its rate.
// The server works it all out again.
const controller = class extends Controller {
  static targets = ["lines", "line", "template", "quantity", "price", "account", "tax", "amount", "destroy",
    "subtotal", "taxTotal", "total", "withholding", "withheldTotal", "payable", "inclusive", "contact", "issued", "due", "currency", "currencyLabel", "rate", "rateCurrency"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.nextIndex = Date.now()
    this.recalculate()
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll("NEW_LINE", String(this.nextIndex++))
    this.linesTarget.insertAdjacentHTML("beforeend", html)
    const line = this.lineTargets.at(-1)
    this.applyDefaults(line)
    line.querySelector("input[type=text]").focus()
    this.recalculate()
  }

  remove(event) {
    const line = event.target.closest("[data-document-lines-target=line]")
    if (line.querySelector("input[name$='[id]']")) {
      line.querySelector("[data-document-lines-target=destroy]").value = "1" // a saved line: the server removes it
      line.hidden = true
    } else {
      line.remove()
    }
    this.recalculate()
  }

  contactChanged() {
    const option = this.contactTarget.selectedOptions[0]
    if (!option || !option.value) return

    const terms = option.dataset.terms
    if (terms !== undefined && terms !== "" && this.hasIssuedTarget && this.issuedTarget.value) {
      const due = new Date(`${this.issuedTarget.value}T00:00:00Z`)
      due.setUTCDate(due.getUTCDate() + Number(terms))
      this.dueTarget.value = due.toISOString().slice(0, 10)
    }
    // Their currency, unless it is fixed (a credit note's is its invoice's).
    const currency = option.dataset.currency
    if (currency && this.hasCurrencyTarget && !this.currencyTarget.disabled && this.currencyTarget.value !== currency) {
      this.currencyTarget.value = currency
      this.currencyChanged()
    }
    this.lineTargets.forEach((line) => this.applyDefaults(line))
    this.recalculate()
  }

  // Another currency: amounts in its minor units, and a rate to the organization's
  // (the first option) unless it is that one.
  currencyChanged() {
    const option = this.currencyTarget.selectedOptions[0]
    this.exponentValue = Number(option.dataset.exponent)
    this.currencyLabelTargets.forEach((label) => { label.textContent = option.value })
    this.rateCurrencyTargets.forEach((label) => { label.textContent = option.value })
    if (this.hasRateTarget) this.rateTarget.hidden = this.currencyTarget.selectedIndex === 0
    this.recalculate()
  }

  // The contact's default account and tax code, on a line that has no account yet.
  applyDefaults(line) {
    const option = this.hasContactTarget && this.contactTarget.selectedOptions[0]
    const account = line.querySelector("[data-document-lines-target=account]")
    if (!option || !option.value || account.value) return

    if (option.dataset.account) account.value = option.dataset.account
    const tax = line.querySelector("[data-document-lines-target=tax]")
    if (option.dataset.tax && !tax.value) tax.value = option.dataset.tax
    const withholding = line.querySelector("[data-document-lines-target=withholding]")
    if (withholding && option.dataset.withholding && !withholding.value) withholding.value = option.dataset.withholding
  }

  recalculate() {
    const inclusive = this.hasInclusiveTarget && this.inclusiveTarget.checked
    let amounts = 0
    let taxes = 0
    let withheld = 0
    this.lineTargets.filter((line) => !line.hidden).forEach((line) => {
      const typed = line.querySelector("[data-document-lines-target=quantity]").value
      const quantity = typed.trim() === "" ? 1 : parseNumber(typed) ?? 0
      const amount = Math.round(quantity * this.parse(line.querySelector("[data-document-lines-target=price]").value))
      const rate = Number(line.querySelector("[data-document-lines-target=tax]").selectedOptions[0]?.dataset.rate || 0)
      const tax = Math.round(inclusive ? amount * rate / (1 + rate) : amount * rate)
      line.querySelector("[data-document-lines-target=amount]").textContent = this.format(amount)
      amounts += amount
      taxes += tax
      const withholding = line.querySelector("[data-document-lines-target=withholding]")
      withheld += Math.round((inclusive ? amount - tax : amount) * Number(withholding?.selectedOptions[0]?.dataset.rate || 0))
    })
    const subtotal = inclusive ? amounts - taxes : amounts
    this.subtotalTarget.textContent = this.format(subtotal)
    this.taxTotalTarget.textContent = this.format(taxes)
    this.totalTarget.textContent = this.format(subtotal + taxes)
    if (this.hasWithheldTotalTarget) {
      this.withheldTotalTarget.textContent = this.format(withheld)
      this.payableTarget.textContent = this.format(subtotal + taxes - withheld)
    }
  }

  // Amounts in the currency's minor units (see tudla_accounting/amounts).
  parse(text) { return parseUnits(text, this.exponentValue) }
  format(units) { return formatUnits(units, this.exponentValue) }
}

return controller;
})());
application.register("entry-lines", (() => {

// The entry form's lines: adds and removes lines, and keeps debit and credit totals
// with a balanced / unbalanced message as amounts are typed. A line with a tax code adds
// its tax (worked out the way the server will, on the same side), or with "amounts include
// the tax" has it split out of its amount. The server checks again.
const controller = class extends Controller {
  static targets = ["lines", "line", "template", "debit", "credit", "destroy", "debitTotal", "creditTotal", "status",
    "tax", "inclusive", "taxRow", "debitTax", "creditTax"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.nextIndex = Date.now()
    this.recalculate()
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll("NEW_LINE", String(this.nextIndex++))
    this.linesTarget.insertAdjacentHTML("beforeend", html)
    this.lineTargets.at(-1).querySelector("select").focus()
    this.recalculate()
  }

  remove(event) {
    const line = event.target.closest("[data-entry-lines-target=line]")
    const destroy = line.querySelector("[data-entry-lines-target=destroy]")
    if (line.querySelector("input[name$='[id]']")) {
      destroy.value = "1" // a saved line: keep it in the form so the server removes it
      line.hidden = true
    } else {
      line.remove()
    }
    this.recalculate()
  }

  recalculate() {
    const live = this.lineTargets.filter((line) => !line.hidden)
    const sum = (field) => live.reduce((total, line) => total + this.parse(line.querySelector(`[data-entry-lines-target=${field}]`).value), 0)
    const inclusive = this.hasInclusiveTarget && this.inclusiveTarget.checked
    const debitTax = this.taxOn(live, "debit", inclusive)
    const creditTax = this.taxOn(live, "credit", inclusive)
    const debit = sum("debit") + (inclusive ? 0 : debitTax)
    const credit = sum("credit") + (inclusive ? 0 : creditTax)
    if (this.hasTaxRowTarget) {
      this.debitTaxTarget.textContent = debitTax ? this.format(debitTax) : ""
      this.creditTaxTarget.textContent = creditTax ? this.format(creditTax) : ""
      this.taxRowTarget.hidden = debitTax === 0 && creditTax === 0
    }

    this.debitTotalTarget.textContent = this.format(debit)
    this.creditTotalTarget.textContent = this.format(credit)

    const difference = debit - credit
    if (debit === 0 && credit === 0) {
      this.show("Enter the amounts for each line.", "tc-muted")
    } else if (difference === 0) {
      this.show(`Balanced: debits equal credits (${this.format(debit)}).`, "text-[var(--tc-success)]")
    } else {
      this.show(`Not balanced: ${difference > 0 ? "debits" : "credits"} are ${this.format(Math.abs(difference))} more.`, "text-[var(--tc-danger)]")
    }
  }

  // The tax on the lines' amounts on one side, rounded per line like the server.
  taxOn(lines, field, inclusive) {
    return lines.reduce((total, line) => {
      const rate = Number(line.querySelector("[data-entry-lines-target=tax]")?.selectedOptions[0]?.dataset.rate || 0)
      const amount = this.parse(line.querySelector(`[data-entry-lines-target=${field}]`).value)
      return total + Math.round(inclusive ? amount * rate / (1 + rate) : amount * rate)
    }, 0)
  }



  show(message, className) {
    this.statusTarget.textContent = message
    this.statusTarget.className = `text-sm ${className}`
  }

  // Amounts in the currency's minor units (see tudla_accounting/amounts).
  parse(text) { return parseUnits(text, this.exponentValue) }
  format(units) { return formatUnits(units, this.exponentValue) }
}

return controller;
})());
application.register("opening-balances", (() => {

// Opening balances: totals the debit-side and credit-side amounts as they are typed and
// says whether they balance. The server checks again before saving.
const controller = class extends Controller {
  static targets = ["amount", "debitTotal", "creditTotal", "status"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.recalculate()
  }

  recalculate() {
    const total = (side) => this.amountTargets
      .filter((input) => input.dataset.side === side)
      .reduce((sum, input) => sum + this.parse(input.value), 0)
    const debit = total("debit")
    const credit = total("credit")

    this.debitTotalTarget.textContent = this.format(debit)
    this.creditTotalTarget.textContent = this.format(credit)
    if (debit === credit) {
      this.show("Balanced.", "text-[var(--tc-success)]")
    } else {
      this.show(`Not balanced: ${debit > credit ? "debits" : "credits"} are ${this.format(Math.abs(debit - credit))} more.`, "text-[var(--tc-danger)]")
    }
  }



  show(message, className) {
    this.statusTarget.textContent = message
    this.statusTarget.className = `text-sm mt-1 ${className}`
  }

  // Amounts in the currency's minor units (see tudla_accounting/amounts).
  parse(text) { return parseUnits(text, this.exponentValue) }
  format(units) { return formatUnits(units, this.exponentValue) }
}

return controller;
})());
application.register("print", (() => {

// Opens the browser's print dialog, where the page can also be saved as a PDF (the
// engine's print styles leave out the navigation and forms): data-action="print#print"
const controller = class extends Controller {
  print() {
    window.print()
  }
}

return controller;
})());
application.register("theme", (() => {

// Switches between light and dark. Saves the choice in localStorage under the key the
// theme_storage_key setting gives ("theme" by default, the key DaisyUI host apps use), so
// the engine and the host stay in step; until a choice is made, or with no key, the page
// follows the operating system's preference.
const controller = class extends Controller {
  static targets = ["sun", "moon"]
  static values = { key: String }

  connect() {
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.refresh = () => this.render()
    this.media.addEventListener("change", this.refresh)
    this.render()
  }

  disconnect() {
    this.media.removeEventListener("change", this.refresh)
  }

  toggle() {
    const theme = this.current() === "dark" ? "light" : "dark"
    document.documentElement.setAttribute("data-theme", theme)
    if (this.keyValue) {
      try { localStorage.setItem(this.keyValue, theme) } catch (_error) { /* storage unavailable: the switch lasts for this page */ }
    }
    this.render()
  }

  current() {
    return document.documentElement.getAttribute("data-theme") || (this.media.matches ? "dark" : "light")
  }

  render() {
    const dark = this.current() === "dark"
    this.element.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme")
    this.element.setAttribute("aria-pressed", String(dark))
    // Offer the sun in dark mode and the moon in light. SVG elements have no `hidden`
    // property, so set the attribute.
    this.sunTarget.toggleAttribute("hidden", !dark)
    this.moonTarget.toggleAttribute("hidden", dark)
  }
}

return controller;
})());
application.register("withheld-cash", (() => {

// On a payment started from an invoice (or bill), the cash starts at all that is owed, and
// comes down by the tax withheld as it's typed, so the two together still settle it. Once
// the cash has been changed by hand, it's left alone. Paying a supplier, typing what the
// tax is withheld from (or choosing the code) works the tax out at the code's rate, and the
// cash is then that amount less the tax.
const controller = class extends Controller {
  static targets = ["cash", "withheld", "base"]
  static values = { exponent: Number, started: Boolean }

  connect() {
    this.full = this.startedValue ? parseUnits(this.cashTarget.value, this.exponentValue) + this.sum(this.withheldTargets) : null
  }

  cashTyped() {
    this.full = null
  }

  baseTyped(event) {
    const row = event.target.closest("tr")
    const base = row.querySelector("[data-withheld-cash-target='base']")
    const withheld = row.querySelector("[data-withheld-cash-target='withheld']")
    const rate = parseFloat(row.querySelector("select")?.selectedOptions[0]?.dataset.rate || "")
    if (!base || !withheld || Number.isNaN(rate) || base.value.trim() === "") return

    withheld.value = fieldUnits(Math.round(parseUnits(base.value, this.exponentValue) * rate), this.exponentValue)
    this.recalculate()
  }

  recalculate() {
    if (this.full === null) return

    const typedBases = this.baseTargets.filter((field) => field.value.trim() !== "")
    const full = typedBases.length > 0 ? this.sum(typedBases) : this.full
    this.cashTarget.value = fieldUnits(Math.max(full - this.sum(this.withheldTargets), 0), this.exponentValue)
  }

  sum(fields) {
    return fields.reduce((total, field) => total + parseUnits(field.value, this.exponentValue), 0)
  }
}

return controller;
})());
})();
