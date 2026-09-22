import Foundation

/// Hides the font-measuring elements some sites leave behind in the page.
///
/// YouTube's mobile site appends probe nodes — `mono-space`, `monospace` — to
/// the body, measures their width to decide whether a font loaded, and expects
/// to take them away again. On m.youtube.com in this app they stay, so two
/// lines of stray monospace text sit in the middle of an otherwise clean page.
///
/// It **hides** rather than removes, and hides with `visibility` rather than
/// `display: none`. Both distinctions matter: the page is still holding a
/// reference to the node and may yet read `offsetWidth` off it, and a node with
/// `display: none` measures zero — which would answer the page's font question
/// with a lie and could change what it renders. Out of flow and invisible keeps
/// the measurement truthful and the text off the screen.
///
/// Matching is on the exact probe strings and only among the body's own first
/// two levels, which is where a probe appended for measurement lands. Anything
/// with children, a link, or a role is left alone — the cost of being wrong
/// here is hiding real content, so the test is narrow on purpose.
enum FontProbeScript {
    static let source = #"""
    (function(){
      var PROBE=/^(mono-space|monospace|sans-serif|BESbswy|giItT1WQy@!-\/#)$/;
      function _hide(el){
        try{
          el.style.setProperty('visibility','hidden','important');
          el.style.setProperty('position','absolute','important');
          el.style.setProperty('left','-9999px','important');
          el.style.setProperty('top','0','important');
        }catch(e){}
      }
      function _isProbe(el){
        if(!el||el.children.length)return false;
        if(el.hasAttribute('href')||el.hasAttribute('role')||el.hasAttribute('onclick'))return false;
        var t=(el.textContent||'').trim();
        return t.length<20&&PROBE.test(t);
      }
      function _sweep(){
        try{
          var body=document.body;if(!body)return;
          for(var i=0;i<body.children.length;i++){
            var el=body.children[i];
            if(el.__panuraProbe)continue;
            if(_isProbe(el)){el.__panuraProbe=true;_hide(el);continue;}
            // A wrapper holding nothing but probes — the commoner shape.
            var kids=el.children,all=kids.length>0,any=false;
            for(var j=0;j<kids.length;j++){
              if(_isProbe(kids[j])){any=true;}else{all=false;break;}
            }
            if(all&&any){el.__panuraProbe=true;_hide(el);}
          }
        }catch(e){}
      }
      _sweep();
      setTimeout(_sweep,800);setTimeout(_sweep,2500);setTimeout(_sweep,5000);
      // A single-page site measures its fonts again after a navigation, so the
      // timers alone would only cover the first page. childList on the body
      // itself, not the subtree: a probe is appended to the body, and watching
      // the subtree of a site like YouTube would mean a callback per render.
      try{
        var _t=0;
        new MutationObserver(function(){
          clearTimeout(_t);_t=setTimeout(_sweep,120);
        }).observe(document.body,{childList:true});
      }catch(e){}
    })();
    """#
}
