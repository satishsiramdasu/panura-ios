import Foundation

/// JS pop/overlay neutralization — ported from Android AdBlocker.neutralisePopJs.
/// Injected at document start so it beats inline pop scripts: kills window.open,
/// stubs aclib.runPop/runBanner, blocks injection of known ad <script> tags, and
/// removes full-screen overlay ads — while sparing age/consent gates.
enum AdBlockScript {
    static let source = #"""
    (function(){
      try { window.open = function(){ return null; }; } catch(e){}
      try { if(typeof aclib!=='undefined'){ aclib.runPop=function(){}; aclib.runBanner=function(){}; } } catch(e){}
      try { Object.defineProperty(window,'aclib',{get:function(){return{runPop:function(){},runBanner:function(){}};},configurable:true}); } catch(e){}

      var _blockedScriptDomains=['displayvertising.com','acscdn.com','acadscdn.com','newpopads.net','popads.net','popcash.net','propellerads.com','exoclick.com','adsterra.com','monetag.com','tsyndicate.com','onclicka.com','onclickads.net','evadav.com'];
      function _isBlockedSrc(src){if(!src)return false;for(var i=0;i<_blockedScriptDomains.length;i++){if(src.indexOf(_blockedScriptDomains[i])!==-1)return true;}return false;}
      function _wrapAppendChild(node){if(!node||!node.appendChild)return;var orig=node.appendChild.bind(node);node.appendChild=function(child){if(child&&child.tagName==='SCRIPT'&&_isBlockedSrc(child.src)){return child;}return orig(child);};}
      try{_wrapAppendChild(document.head||document.documentElement);}catch(e){}
      var _origBody=Object.getOwnPropertyDescriptor(Document.prototype,'body');
      if(_origBody&&_origBody.get){try{Object.defineProperty(document,'body',{get:function(){var b=_origBody.get.call(this);if(b&&!b.__panuraWrapped){b.__panuraWrapped=true;_wrapAppendChild(b);}return b;},configurable:true});}catch(e){}}

      var _keepRe=/18|adult|age|older|enter|agree|accept|consent|continue|verify|confirm|disclaimer|warning|proceed|leave|exit|yes|no\b/i;
      function _rmOv(){try{document.querySelectorAll('*').forEach(function(el){try{var s=window.getComputedStyle(el),z=parseInt(s.zIndex)||0;if(z>999&&(s.position==='fixed'||s.position==='absolute')){var r=el.getBoundingClientRect();if(r.width>window.innerWidth*0.8&&r.height>window.innerHeight*0.8){var t=el.tagName.toLowerCase(),id=(el.id||'').toLowerCase(),cls=(el.className||'').toString().toLowerCase();if(t==='video'||t==='canvas'||id.indexOf('player')!==-1||cls.indexOf('player')!==-1)return;var txt=(el.textContent||'').slice(0,600);if(el.querySelector('button,a[href],input,form,[role=button],[onclick]')&&_keepRe.test(txt))return;el.remove();}}}catch(e){}});}catch(e){}}
      setTimeout(_rmOv,800);setTimeout(_rmOv,2500);setTimeout(_rmOv,5000);
    })();
    """#
}
