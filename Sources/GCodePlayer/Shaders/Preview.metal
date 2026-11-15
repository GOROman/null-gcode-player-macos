#include <metal_stdlib>
using namespace metal;
struct Instance { float4 a,b,color,timing; };
struct Uniforms { float4x4 vp,lightVP; float4 head,eye,clock,filament,flow,beadShape; };
struct Out { float4 position [[position]]; float3 world,normal; float4 color; float kind,heat; float4 lightPosition; float depositedAt; };
vertex Out bead(uint vid [[vertex_id]],uint instance [[instance_id]],constant Instance *segments [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    Instance s=segments[instance];
    float3 a=s.a.xyz,b=s.b.xyz;
    if(s.timing.w==2) { a+=u.head.xyz;b+=u.head.xyz; }
    if(s.timing.w==0 && u.clock.x<s.timing.y) b=mix(a,b,clamp((u.clock.x-s.timing.x)/max(.00001f,s.timing.y-s.timing.x),0.f,1.f));
    constexpr uint endpoint[6]={0,1,0,0,1,1};
    bool atEnd=vid<48 ? endpoint[vid%6]!=0 : (s.timing.w==0?vid>=72:vid>=54);
    float depositedAt=atEnd?min(u.clock.x,s.timing.y):s.timing.x;
    float heat=s.timing.w==0 && u.clock.z>0 ? exp(-max(0.f,u.clock.x-depositedAt)/max(1.f,u.clock.y)*2.0f):0;
    if(s.timing.w==0 && u.clock.z>0) {
        float3 direction=normalize(b-a+float3(.000001,0,0));
        // Small bead overlap closes seams without allocating new join geometry.
        a-=direction*.018;b+=direction*.018;s.a.w*=1.17+heat*.07;s.b.w*=1.24-heat*.16;
    }
    float3 along=normalize(b-a+float3(.000001,0,0)),side=normalize(cross(along,float3(0,1,0)));
    float3 up=normalize(cross(side,along));
    constexpr float2 ring[8]={float2(-1,-.5),float2(-.75,-1),float2(.75,-1),float2(1,-.5),float2(1,.5),float2(.75,1),float2(-.75,1),float2(-1,.5)};
    constexpr float2 roundRing[8]={float2(-1,0),float2(-.7071,-.7071),float2(0,-1),float2(.7071,-.7071),float2(1,0),float2(.7071,.7071),float2(0,1),float2(-.7071,.7071)};
    float3 world,normal;
    if(u.clock.w>0) {
        constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[vid%6];
        float crossSection=c>=2?1.f:-1.f;
        world=(c%2==0?a:b);
        if(vid<6) {world+=side*crossSection*s.a.w*.35+up*s.b.w*.35;normal=up;}
        else {world+=up*crossSection*s.b.w*.5;normal=side;}
    } else if(vid<48) {
        uint face=vid/6,k=vid%6;constexpr uint corner[6]={0,1,2,2,1,3};uint c=corner[k],r=(face+(c>=2?1:0))%8;
        float2 profile=ring[r];
        if(s.timing.w==0) {
            profile=roundRing[r];
            // Cooling retains the expanded, contacting cross-section. Fresh material
            // is round; settled material relaxes to a rounded fused bead profile.
            if(u.clock.z>0) profile=sign(profile)*pow(abs(profile),float2(mix(.48f,1.f,heat)));
        }
        world=(c%2==0?a:b)+side*profile.x*s.a.w*.5+up*profile.y*s.b.w*.5;
        float2 n=normalize(float2(ring[(face+1)%8].y-ring[face].y,ring[face].x-ring[(face+1)%8].x));normal=s.timing.w==0?normalize(side*profile.x+up*profile.y):normalize(side*n.x+up*n.y);
    } else if(s.timing.w==0) {
        // Eight-triangle fans close the complete rounded outline at both ends.
        uint local=(vid-48)%24,sector=local/3,corner=local%3;
        float2 profile=corner==0?float2(0):roundRing[(sector+(corner==2?1:0))%8];
        if(u.clock.z>0)profile=sign(profile)*pow(abs(profile),float2(mix(.48f,1.f,heat)));
        bool end=vid>=72;world=(end?b:a)+side*profile.x*s.a.w*.5+up*profile.y*s.b.w*.5;normal=end?along:-along;
    } else {
        uint k=(vid-48)%6;constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[k];float2 r=float2(c>=2?1:-1,c%2==0?-1:1);
        bool end=vid>=54;world=(end?b:a)+side*r.x*s.a.w*.5+up*r.y*s.b.w*.5;normal=end?along:-along;
    }
    return {u.vp*float4(world,1),world,normal,s.color,s.timing.w,heat,u.lightVP*float4(world,1),depositedAt};
}
struct HeadVertex {float4 position,normal,color;};
vertex Out toolhead(uint vid [[vertex_id]],constant HeadVertex *mesh [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    HeadVertex value=mesh[vid];float3 world=value.position.xyz+u.head.xyz;
    float4 color=value.color.a<0?u.filament:value.color;
    return {u.vp*float4(world,1),world,value.normal.xyz,color,2,0,u.lightVP*float4(world,1),0};
}
// Screen-facing elliptical ribbon: two triangles for distant beads instead of
// generating the complete tube. Lighting normals retain a rounded appearance.
vertex Out ribbon(uint vid [[vertex_id]],uint instance [[instance_id]],constant Instance *segments [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    Instance s=segments[instance];float3 a=s.a.xyz,b=s.b.xyz;
    if(u.clock.x<s.timing.y)b=mix(a,b,clamp((u.clock.x-s.timing.x)/max(.00001f,s.timing.y-s.timing.x),0.f,1.f));
    float3 along=normalize(b-a+float3(.000001,0,0)),horizontal=normalize(cross(along,float3(0,1,0))),up=normalize(cross(horizontal,along));
    float3 facing=normalize(u.eye.xyz-(a+b)*.5),side=normalize(cross(along,facing));
    float radius=.5*length(float2(dot(side,horizontal)*s.a.w,dot(side,up)*s.b.w));
    if(u.clock.z>0)radius*=1.19;
    constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[vid];float sign=c>=2?1.f:-1.f;
    float3 world=(c%2==0?a:b)+side*(sign*radius),normal=normalize(facing*.6+side*sign*.8);
    return {u.vp*float4(world,1),world,normal,s.color,0,0,u.lightVP*float4(world,1),c%2==0?s.timing.x:min(u.clock.x,s.timing.y)};
}
// A small smooth meniscus joins the nozzle outlet to the deposited strand.
// It is generated only for the active extrusion, never for travel/retraction.
vertex Out moltenJoin(uint vid [[vertex_id]],constant Uniforms &u [[buffer(1)]]) {
    constexpr uint corners[6]={0,1,2,2,1,3};uint cell=vid/6,c=corners[vid%6];
    float latitude=float(cell/16+(c>=2?1:0))/8.f,longitude=float(cell%16+(c%2!=0?1:0))/16.f;
    float theta=latitude*M_PI_F,phi=longitude*2*M_PI_F;
    float3 sphere=float3(sin(theta)*cos(phi),cos(theta),sin(theta)*sin(phi));
    float3 along=normalize(u.flow.xyz+float3(.000001,0,0)),side=normalize(cross(along,float3(0,1,0))),up=normalize(cross(side,along));
    float3 radius=float3(u.beadShape.x*.92,u.beadShape.y*.56,u.beadShape.x*.61)*u.flow.w;
    float3 center=u.head.xyz-along*u.beadShape.x*.24-up*u.beadShape.y*.14;
    float3 world=center+along*sphere.x*radius.x+up*sphere.y*radius.y+side*sphere.z*radius.z;
    float3 normal=normalize(along*sphere.x/max(.0001f,radius.x)+up*sphere.y/max(.0001f,radius.y)+side*sphere.z/max(.0001f,radius.z));
    return {u.vp*float4(world,1),world,normal,u.filament,3,1,u.lightVP*float4(world,1),u.clock.x};
}
fragment float4 shaded(Out in [[stage_in]],constant Uniforms &u [[buffer(1)]],depth2d<float> shadowMap [[texture(0)]]) {
    float heat=in.heat;
    if(in.kind==0 && u.clock.z>0)heat=exp(-max(0.f,u.clock.x-in.depositedAt)/max(1.f,u.clock.y)*2.0f);
    float3 base=in.color.rgb,n=normalize(in.normal),v=normalize(u.eye.xyz-in.world),l=normalize(float3(-.4,1,.5));
    if(in.kind==1 && n.y>.5) {
        float2 p=in.world.xz/10,deriv=max(fwidth(p),float2(.0001));float2 grid=abs(fract(p-.5)-.5)/deriv;float line=1-min(min(grid.x,grid.y),1.f);base=mix(base,float3(.018,.027,.03),line*.45);
    }
    float visibility=1;
    if(u.head.w>0) {
        float3 p=in.lightPosition.xyz/in.lightPosition.w;float2 uv=float2(p.x*.5+.5,.5-p.y*.5);
        constexpr sampler shadowSampler(coord::normalized,filter::linear,compare_func::less_equal,address::clamp_to_edge);
        if(all(uv>0.f)&&all(uv<1.f)&&p.z>0&&p.z<1){
            float texelScale=1024.f/float(shadowMap.get_width());float bias=max(.00012f,.0007f*(1-dot(n,l)))*texelScale;visibility=0;
            if(u.head.w<.75) visibility=shadowMap.sample_compare(shadowSampler,uv,p.z-bias);
            else for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++)visibility+=shadowMap.sample_compare(shadowSampler,uv+float2(x,y)/float2(shadowMap.get_width(),shadowMap.get_height()),p.z-bias)/9.f;
            visibility=mix(.35f,1.f,visibility);
        }
    }
    float diffuse=max(dot(n,l),0.f)*visibility,spec=pow(max(dot(n,normalize(l+v)),0.f),in.kind==1?8.f:mix(70.f,145.f,heat));
    float rim=pow(1-max(dot(n,v),0.f),3.f)*max(dot(n,normalize(float3(.6,.5,-1))),0.f);
    float3 color=base*(.28+1.7*diffuse+rim*.2)+spec*visibility*(in.kind==1?.006:mix(.25,.85,heat));
    color=color/(1+color);color=pow(max(color,0.f),float3(1/2.2f));return float4(color,in.color.a);
}

// Closest points on two finite segments, including parallel and degenerate cases.
float2 filamentClosest(float3 p,float3 q,float3 a,float3 b) {
    float3 d=q-p,e=b-a,r=p-a;
    float dd=dot(d,d),ee=dot(e,e),de=dot(d,e),dr=dot(d,r),er=dot(e,r);
    float s=0,t=0;
    if(dd<1e-8f) return float2(0,ee>1e-8f?clamp(er/ee,0.f,1.f):0.f);
    if(ee<1e-8f) return float2(clamp(-dr/dd,0.f,1.f),0);
    float denom=dd*ee-de*de;
    if(denom>1e-8f)s=clamp((de*er-dr*ee)/denom,0.f,1.f);
    t=(de*s+er)/ee;
    if(t<0){t=0;s=clamp(-dr/dd,0.f,1.f);}
    else if(t>1){t=1;s=clamp((de-dr)/dd,0.f,1.f);}
    return float2(s,t);
}
kernel void filamentContacts(const device float4 *input [[buffer(0)]],device float4 *output [[buffer(1)]],constant uint &count [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=count)return;
    float4 node=input[i]; float3 correction=0;float contacts=0;
    if(node.w>0) for(uint side=0;side<2;side++) {
        if((side==0&&i==0)||(side==1&&i+1>=count))continue;
        uint first=side==0?i-1:i,second=first+1;
        float3 p=input[first].xyz,q=input[second].xyz;
        for(uint j=0;j+1<count;j++) {
            if(abs(int(j)-int(first))<=2)continue;
            float3 a=input[j].xyz,b=input[j+1].xyz;
            if(any(max(min(p,q),min(a,b))-min(max(p,q),max(a,b))>float3(.44)))continue;
            float2 st=filamentClosest(p,q,a,b);
            float3 delta=mix(p,q,st.x)-mix(a,b,st.y);float dist=length(delta);
            if(dist>=.44f)continue;
            float weight=side==0?st.x:1-st.x;
            float other=mix(input[j].w,input[j+1].w,st.y);
            float3 normal=dist>1e-5f?delta/dist:float3(0,1,0);
            correction+=normal*(.44f-dist)*weight*node.w/max(.001f,node.w+other);
            contacts+=1;
        }
    }
    if(contacts>0)node.xyz+=correction/max(1.f,contacts)*.8f;
    node.y=max(.22f,node.y);output[i]=node;
}
