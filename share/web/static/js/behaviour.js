/*
   Modified version. Use jQuery as css query engine.
   
   Based on Behaviour v1.1 by Ben Nolan, June 2005, which was based
   largely on the work of Simon Willison.
 
   Usage:   
   
    var myrules = {
        'b.someclass' : function(element){
            element.onclick = function(){
                alert(this.innerHTML);
            }
        },
        '#someid u' : function(element){
            element.onmouseover = function(){
                this.innerHTML = "BLAH!";
            }
        }
    };
    
    Behaviour.register(myrules);
    
    // Call Behaviour.apply() to re-apply the rules (if you
    // update the dom, etc).

*/   

var Behaviour = {
    list: [],

    register: function(sheet) {
        Behaviour.list.push(sheet);
    },
    
    apply: function() {
        var root = arguments[0];
        if(root) root = $(root);

        for (var h = 0; sheet = Behaviour.list[h]; h++) {
            for (var selector in sheet) {
                var start = new Date();
                var elements = jQuery(selector, root);

                if ( !elements ) continue;

                for (var i = 0; element = elements[i]; i++) {
                    sheet[selector](element);
                }
            }
        }
    }
};

(function($) {
    $(document).ready(function(){
        Behaviour.apply();
    });
})(jQuery);
