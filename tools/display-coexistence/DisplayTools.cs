using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.IO;
/// <summary>Windows display topology operations for the supported MikeTheTech provider. No driver installation occurs here.</summary>
public static class SunshineDisplays {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Device {
  public int cb; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string name;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string description; public uint flags;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string id;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string key;
 }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Mode {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string device;
  public ushort spec,driver,size,extra; public uint fields; public int x,y; public uint orientation,fixedOutput;
  public short color,duplex,yResolution,tt,collate;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string form;
  public ushort logPixels; public uint bits,width,height,flags,frequency,icm,icmIntent,media,dither,reserved1,reserved2,panningWidth,panningHeight;
 }
 public class Output {
  public string Name,Adapter,Monitor,Id; public bool Active,Primary,Virtual; public int X,Y; public uint Width,Height,Hz;
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string device,uint index,ref Device output,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string device,int index,ref Mode mode);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device,ref Mode mode,IntPtr window,uint flags,IntPtr parameter);
 [StructLayout(LayoutKind.Sequential,Pack=4)] public struct Source { public long adapter; public uint id,mode,status; }
 [StructLayout(LayoutKind.Sequential,Pack=4)] public struct Target { public long adapter;public uint id,mode,technology,rotation,scaling,numerator,denominator,scan;public int available;public uint status; }
 [StructLayout(LayoutKind.Sequential,Pack=4)] public struct Path {public Source source;public Target target;public uint flags;}
 public class Topology {public Path[] paths;public byte[] modes;}
 [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
 [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags,ref uint pathCount,IntPtr paths,ref uint modeCount,IntPtr modes,IntPtr topology);
 [DllImport("user32.dll")] static extern int SetDisplayConfig(uint pathCount,IntPtr paths,uint modeCount,IntPtr modes,uint flags);
 [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr info);
 public static Topology Query(uint flags) {
  if(Marshal.SizeOf(typeof(Path))!=72)throw new Exception("Display path structure size mismatch");
  for(int attempt=0;attempt<5;attempt++) {
   uint pc,mc;int result=GetDisplayConfigBufferSizes(flags,out pc,out mc);if(result!=0)throw new Exception("Display query sizes failed: "+result);
   IntPtr pp=Marshal.AllocHGlobal((int)pc*72),mp=Marshal.AllocHGlobal((int)mc*64);
   try {
    result=QueryDisplayConfig(flags,ref pc,pp,ref mc,mp,IntPtr.Zero);if(result==122)continue;if(result!=0)throw new Exception("Display query failed: "+result);
    var paths=new Path[pc];for(int i=0;i<pc;i++)paths[i]=(Path)Marshal.PtrToStructure(IntPtr.Add(pp,i*72),typeof(Path));
    var modes=new byte[mc*64];Marshal.Copy(mp,modes,0,modes.Length);return new Topology{paths=paths,modes=modes};
   } finally {Marshal.FreeHGlobal(pp);Marshal.FreeHGlobal(mp);}
  }throw new Exception("Display query kept changing");
 }
 public static string TargetName(Target target) {
  IntPtr ptr=Marshal.AllocHGlobal(420);try {
   Marshal.Copy(new byte[420],0,ptr,420);Marshal.WriteInt32(ptr,0,2);Marshal.WriteInt32(ptr,4,420);Marshal.WriteInt64(ptr,8,target.adapter);Marshal.WriteInt32(ptr,16,(int)target.id);
   if(DisplayConfigGetDeviceInfo(ptr)!=0)return "";return Marshal.PtrToStringUni(IntPtr.Add(ptr,164));
  }finally{Marshal.FreeHGlobal(ptr);}
 }
 public static int Apply(Topology data,bool test) {
  IntPtr pp=Marshal.AllocHGlobal(data.paths.Length*72),mp=Marshal.AllocHGlobal(data.modes.Length);
  try {
   for(int i=0;i<data.paths.Length;i++)Marshal.StructureToPtr(data.paths[i],IntPtr.Add(pp,i*72),false);
   Marshal.Copy(data.modes,0,mp,data.modes.Length);
   return SetDisplayConfig((uint)data.paths.Length,pp,(uint)(data.modes.Length/64),mp,0x20u|(test?0x40u:0x80u));
  }finally{Marshal.FreeHGlobal(pp);Marshal.FreeHGlobal(mp);}
 }
 public static void SaveTopology(string filename) {
  WriteTopology(Query(2),filename);
 }
 public static void SaveOriginalTopology(string filename) {
  WriteTopology(OriginalTopology(),filename);
 }
 public static int ParkVirtualDisplays() {
  var filtered=OriginalTopology();
  return Apply(filtered,false);
 }
 static Topology OriginalTopology() {
  var data=Query(2);var paths=new List<Path>();var modes=new List<byte>();var map=new Dictionary<uint,uint>();
  Func<uint,uint> remap=index=>{
   if(index==uint.MaxValue)return index;
   if(!map.ContainsKey(index)){
    if(index>=data.modes.Length/64)throw new Exception("Invalid mode index");
    map[index]=(uint)(modes.Count/64);
    for(int i=0;i<64;i++)modes.Add(data.modes[(int)index*64+i]);
   }return map[index];
  };
  foreach(var original in data.paths){
   if(TargetName(original.target).Contains("MTT1337"))continue;
   var p=original;p.source.mode=remap(p.source.mode);p.target.mode=remap(p.target.mode);paths.Add(p);
  }
  if(paths.Count==0)throw new Exception("No existing original display to preserve");
  var filtered=new Topology{paths=paths.ToArray(),modes=modes.ToArray()};
  int validation=Apply(filtered,true);if(validation!=0)throw new Exception("Original display recovery validation failed: "+validation);
  return filtered;
 }
 static void WriteTopology(Topology data,string filename) {
  using(var writer=new BinaryWriter(File.Create(filename))) {
   writer.Write(data.paths.Length);writer.Write(data.modes.Length);
   IntPtr ptr=Marshal.AllocHGlobal(72);try {foreach(var path in data.paths){Marshal.StructureToPtr(path,ptr,false);var bytes=new byte[72];Marshal.Copy(ptr,bytes,0,72);writer.Write(bytes);}}finally{Marshal.FreeHGlobal(ptr);}
   writer.Write(data.modes);
  }
 }
 public static int RestoreTopology(string filename) {
  using(var reader=new BinaryReader(File.OpenRead(filename))) {
   int pc=reader.ReadInt32(),mc=reader.ReadInt32();if(pc<1||pc>100||mc<64||mc>64000||mc%64!=0)throw new Exception("Invalid recovery topology");
   var paths=new Path[pc];IntPtr ptr=Marshal.AllocHGlobal(72);try {for(int i=0;i<pc;i++){var bytes=reader.ReadBytes(72);if(bytes.Length!=72)throw new Exception("Truncated recovery topology");Marshal.Copy(bytes,0,ptr,72);paths[i]=(Path)Marshal.PtrToStructure(ptr,typeof(Path));}}finally{Marshal.FreeHGlobal(ptr);}
   var modes=reader.ReadBytes(mc);if(modes.Length!=mc||reader.BaseStream.Position!=reader.BaseStream.Length)throw new Exception("Truncated or trailing recovery modes");return Apply(new Topology{paths=paths,modes=modes},false);
  }
 }
 public static int AttachVirtual(int x,int y) {
  var active=Query(2);var all=Query(1);Path chosen=new Path();bool found=false;
  foreach(var candidate in all.paths) {
   if(candidate.target.available==0||!TargetName(candidate.target).Contains("MTT1337"))continue;
   bool occupied=false;foreach(var p in active.paths)if(p.source.adapter==candidate.source.adapter&&p.source.id==candidate.source.id)occupied=true;
   if(!occupied){chosen=candidate;found=true;break;}
  }
  if(!found)throw new Exception("No available separate virtual-display path");
  chosen.flags=1;chosen.source.mode=uint.MaxValue;chosen.target.mode=uint.MaxValue;
  var modes=active.modes;
  var paths=new Path[active.paths.Length+1];Array.Copy(active.paths,paths,active.paths.Length);paths[paths.Length-1]=chosen;
  var data=new Topology{paths=paths,modes=modes};int validation=Apply(data,true);if(validation!=0)return validation;return Apply(data,false);
 }
 public static Output[] List() {
  var result=new List<Output>();
  for(uint i=0;;i++) {
   var d=new Device{cb=Marshal.SizeOf(typeof(Device))}; if(!EnumDisplayDevices(null,i,ref d,0))break;
   var m=new Mode{size=(ushort)Marshal.SizeOf(typeof(Mode))}; bool current=EnumDisplaySettings(d.name,-1,ref m);
   var child=new Device{cb=Marshal.SizeOf(typeof(Device))}; EnumDisplayDevices(d.name,0,ref child,0);
   result.Add(new Output{Name=d.name,Adapter=d.description,Monitor=child.description,Id=child.id,
    Active=(d.flags&1)!=0,Primary=(d.flags&4)!=0,Virtual=(child.id??"").Contains("MTT1337"),
    X=current?m.x:0,Y=current?m.y:0,Width=current?m.width:0,Height=current?m.height:0,Hz=current?m.frequency:0});
  } return result.ToArray();
 }
 public static Mode[] Modes(string name) {
  var result=new List<Mode>(); for(int i=0;;i++) {var m=new Mode{size=(ushort)Marshal.SizeOf(typeof(Mode))};if(!EnumDisplaySettings(name,i,ref m))break;result.Add(m);}return result.ToArray();
 }
 public static int SetMode(string name,uint width,uint height,uint hz,bool test) {
  var m=new Mode{size=(ushort)Marshal.SizeOf(typeof(Mode))}; if(!EnumDisplaySettings(name,-1,ref m))throw new Exception("Current display mode unavailable");
  m.fields=0x00040000|0x00080000|0x00100000|0x00400000; m.width=width;m.height=height;m.frequency=hz;
  return ChangeDisplaySettingsEx(name,ref m,IntPtr.Zero,test?2u:0u,IntPtr.Zero);
 }
 public static int Attach(string name,int x,int y) {
  var available=Modes(name); Mode selected=new Mode();bool found=false;
  foreach(var mode in available)if(mode.width==1920&&mode.height==1080&&mode.frequency==60){selected=mode;found=true;break;}
  if(!found)throw new Exception("Required safe 1080p60 mode unavailable");
  selected.x=x;selected.y=y;selected.fields=0x20|0x00040000|0x00080000|0x00100000|0x00400000;
  return ChangeDisplaySettingsEx(name,ref selected,IntPtr.Zero,0,IntPtr.Zero);
 }
}
