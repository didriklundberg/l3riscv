(* Copyright (C) 2014, 2015 Anthony Fox, University of Cambridge
 * Copyright (C) 2014, 2015 Alexandre Joannou, University of Cambridge
 * Copyright (C) 2015-2018, SRI International.
 *
 * This software was developed by SRI International and the University of
 * Cambridge Computer Laboratory under DARPA/AFRL contract FA8750-11-C-0249
 * ("MRC2"), as part of the DARPA MRC research programme, and under
 * DARPA/AFRL contract FA8750-10-C-0237 ("CTSRD"), as part of the DARPA
 * CRASH research programme.
 *
 * See the LICENSE file for details.
 *)

(* --------------------------------------------------------------------------
   RISCV emulator
   -------------------------------------------------------------------------- *)

(* Default Configuration *)

val mem_base_addr   = ref (IntInf.fromInt 0x80000000) (* default used in spike *)
val mem_size        = ref (IntInf.fromInt 0)

(* Execution parameters *)

(* true  -> init starting PC to reset vector
   false -> use start offset from ELF *)
val boot        = ref false
val reset_addr  = 0x1000  (* default used in spike *)

val be          = ref false (* little-endian *)
val time_run    = ref true

val trace_lvl   = ref (0 : int)
val trace_elf   = ref false

val check           = ref false
val checker_exit_pc = ref (Word64.fromInt (~1))

val verifier_mode       = ref false
val verifier_exe_name   = "SIM_ELF_FILENAME"
val verifier_trace_lvl  = ref 1

(* Utilities *)

fun hex s  = L3.lowercase (BitsN.toHexString s)
fun phex n = StringCvt.padLeft #"0" (n div 4) o hex
val hex32  = phex 32
val hex64  = phex 64

fun hx32  n = Word32.fmt StringCvt.HEX n
fun hx64  n = Word64.fmt StringCvt.HEX n
fun hxi   n = Int.fmt    StringCvt.HEX n
fun hxi64 n = IntInf.fmt StringCvt.HEX n

fun failExit s = ( print (s ^ "\n"); OS.Process.exit OS.Process.failure )
fun err e s = failExit ("Failed to " ^ e ^ " file \"" ^ s ^ "\"")

fun debugPrint s = print("==DEBUG== "^s)
fun debugPrintln s = print("==DEBUG== "^s^"\n")

fun mkMask64 w =
    Word64.-(Word64.<<(Word64.fromInt 0x1,
                       Word.fromInt (IntInf.toInt (BitsN.toUInt w))),
             Word64.fromInt 0x1)

(* Bit vector utilities *)

fun word8ToBits8 word8 =
    BitsN.fromInt (Word8.toLargeInt word8, 8)

fun getByte v i =
    if   i < Word8Vector.length v
    then word8ToBits8 (Word8Vector.sub (v, i))
    else BitsN.zero 8

(* Memory utilities *)

(* TODO: this might be broken for big-endian code, but RISCV is
   little-endian by default. *)
fun storeVecInMemHelper vec (base : int) (i : int) =
    let val j = 8*i;
        val bytes0  = List.tabulate (8, fn inner => getByte vec (j+inner));
        val bytes1  = if !be then bytes0 else rev bytes0
        val bits64  = BitsN.concat bytes1
        val addr    = IntInf.fromInt (base + j)
    in  if   j < Word8Vector.length vec
        then ( riscv.rawWriteMem (BitsN.fromInt (addr, IntInf.fromInt 64), bits64)
             ; storeVecInMemHelper vec base (i+1)
             )
        else
            if !trace_elf
            then print (Int.toString (Word8Vector.length vec) ^ " words.\n")
            else ()
    end

fun storeVecInMem (base : int, memsz : int, vec) =
    let val vlen   = Word8Vector.length vec
        val padded = if memsz <= vlen then vec
                     else (
                         let val pad = Word8Vector.tabulate
                                           (memsz - vlen,  (fn _ => Word8.fromInt 0))
                         in  Word8Vector.concat (vec :: pad :: [])
                         end
                     )
    in  storeVecInMemHelper padded base 0
    end

(* Multi-core utilities *)

fun currentCore () =
    BitsN.toInt (!riscv.procID)

fun nextCoreToSchedule () =
    (1 + currentCore ()) mod !riscv.totalCore

fun isLastCore () =
    BitsN.toInt (!riscv.procID) + 1 = !riscv.totalCore

(* Printing utilities *)

fun printLog () =
    ( List.app (fn (n, l) =>
                   if IntInf.toInt n <= !trace_lvl
                   then print (l ^ "\n")
                   else ()
               ) (List.rev (!riscv.log))
    ; riscv.clear_logs ()
    )

local
    fun readReg i = hex64 (riscv.GPR (BitsN.fromNat (i, 5)))
in
fun dumpRegisters core =
    let val savedCore   = currentCore ()
        val pc          = riscv.Map.lookup(!riscv.c_PC, core)
    in  riscv.scheduleCore core
      ; print "======   Registers   ======\n"
      ; print ("Core = " ^ IntInf.toString core ^ "\n")
      ; let val w   = #rinstr (riscv.Delta ())
            val i   = riscv.Decode w
        in  print ("Faulting instruction: (0x" ^ hex32 w ^ ") "
                   ^ riscv.instructionToString i
                   ^ "\n\n")
        end

      ; print ("PC     " ^ hex64 pc ^ "\n")
      ; L3.for
            (IntInf.fromInt 0, IntInf.fromInt 31,
             fn i =>
                print ("reg " ^ (if IntInf.< (i, 10) then " " else "") ^
                       IntInf.toString i ^ " " ^ readReg i ^ "\n"))
      ; riscv.scheduleCore savedCore
    end
end

fun disassemble pc range =
    if range <= 0 then ()
    else let val addr = BitsN.fromInt (pc, IntInf.fromInt 64)
             val word = riscv.rawReadInst (addr)
             val inst = riscv.Decode word
         in  print ("0x" ^ (L3.padLeftString(#"0", (10, BitsN.toHexString addr)))
                    ^ ": 0x" ^ hex32 word
                    ^ ": " ^ riscv.instructionToString inst
                    ^ "\n"
                   )
           ; disassemble (pc + 4) (range - 4)
         end

fun verifierTrace (lvl, str) =
    if   lvl <= !verifier_trace_lvl
    then print (String.concat ["L3RISCV: ", str, "\n"])
    else ()

(* Tandem verification:
   client interface: disabled pending a new implementation *)

fun initChecker () =
    ()

fun loadChecker filename =
    ()

fun doCheck () =
    if true
    then ()
    else ( print "Verification error:\n"
         ; dumpRegisters (currentCore ())
         ; failExit "Verification FAILED!\n"
         )

fun isCheckerDone () =
    if !check then
        let val pc   = BitsN.toUInt (riscv.Map.lookup(!riscv.c_PC, 0))
            val pc64 = Word64.fromInt (IntInf.toInt pc)
        in  Word64.compare (!checker_exit_pc, pc64) = EQUAL
        end
    else false

(* Code execution *)

fun logLoop mx i =
    ( riscv.scheduleCore (nextCoreToSchedule ())
    ; riscv.Next ()
    ; print ("\n")
    ; printLog ()
    ; if !check then doCheck() else ()
    ; if !riscv.done orelse i = mx orelse isCheckerDone ()
      then ( print ("ExitCode: " ^ Nat.toString (riscv.exitCode ()) ^ "\n")
           ; print ("Completed " ^ Int.toString (i + 1) ^ " instructions.\n")
           )
      else logLoop mx (if isLastCore () then (i + 1) else i)
    )

fun decr i = if i <= 0 then i else i - 1

fun silentLoop mx =
    ( riscv.scheduleCore (nextCoreToSchedule ())
    ; riscv.Next ()
    ; riscv.clear_logs ()
    ; if !check then doCheck() else ()
    ; if !riscv.done orelse (mx = 1) orelse isCheckerDone ()
      then let val ec = riscv.exitCode ()
           in  print ("done: exit code " ^ Nat.toString ec ^ "\n")
             ; OS.Process.exit (if ec = 0
                                then OS.Process.success
                                else OS.Process.failure)
           end
      else silentLoop (if isLastCore () then (decr mx) else mx)
    )

local
    fun t f x = if !time_run then Runtime.time f x else f x
in
fun run mx =
    if   1 <= !trace_lvl
    then t (logLoop mx) 0
    else t silentLoop mx

fun runWrapped mx =
    run mx
    handle riscv.UNDEFINED s =>
           ( dumpRegisters (currentCore ())
           ; failExit ("UNDEFINED \"" ^ s ^ "\"\n")
           )
         | riscv.INTERNAL_ERROR s =>
           ( dumpRegisters (currentCore ())
           ; failExit ("INTERNAL_ERROR \"" ^ s ^ "\"\n")
           )
end

(* Platform initialization *)

fun insertBootCode () =
    let val auipc_val = IntInf.-(!mem_base_addr, IntInf.fromInt reset_addr)
        val auipc_imm = BitsN.>>+ (BitsN.fromInt (auipc_val, IntInf.fromInt 32),
                                   12)
        val boot_code =
            [ (* auipc t0, 0x7ffff *)
              riscv.ArithI(riscv.AUIPC(BitsN.fromNat (5, 5), auipc_imm))
            , (* jr t0 *)
              riscv.Branch(riscv.JALR(BitsN.fromNat (0, 5), (BitsN.fromNat (5, 5), BitsN.zero 12)))
            ]
        val boot_vec = List.map riscv.Encode boot_code
        fun insert (addr : IntInf.int) insns =
            case insns of
                i :: tl        => ( riscv.rawWriteData (BitsN.fromInt (addr, 64), (i, 4))
                                  ; insert (IntInf.+ (addr, 4)) tl
                                  )
              | []             => ()
    in print ("L3RISCV: Loading reset code at " ^ hxi reset_addr ^ "\n")
     ; insert (IntInf.fromInt reset_addr) (List.map riscv.Encode boot_code)
    end

fun initPlatform cores =
    ( riscv.print     := debugPrint
    ; riscv.println   := debugPrintln
    ; riscv.procID    := BitsN.B(0, BitsN.size(!riscv.procID))
    ; riscv.totalCore := cores
    ; riscv.initMem (BitsN.fromInt
                         ((if !check then 0xaaaaaaaaAAAAAAAA else 0x0)
                         , 64))
    ; if !check
      then initChecker ()
      else ()
    ; if !boot
      then insertBootCode ()
      else ()
    )

(* assumes riscv.procID is 0 *)
fun initCores (arch, pc) =
    ( riscv.initIdent arch
    ; riscv.initMachine (!riscv.procID)
    ; riscv.initRegs pc
    ; if isLastCore ()
      then ()  (* core scheduler will wrap back to first core *)
      else ( riscv.scheduleCore (nextCoreToSchedule ())
           ; initCores (arch, pc)
           )
    )

(* Program load *)

fun loadElf segms dis =
    List.app (fn s =>
                 if (#ptype s) = Elf.PT_LOAD
                 then (let val vaddr   = Int.fromLarge (#vaddr s)
                           val memsz   = Int.fromLarge (#memsz s)
                           val mem_end = IntInf.toInt (IntInf.+ (!mem_base_addr, !mem_size))
                       in
                           if !trace_elf
                           then ( print ( "Loading segment ...\n")
                                ; Elf.printSegment s
                                )
                           else ()
                         ; storeVecInMem (vaddr, memsz, (#bytes s))
                         (* update memory range *)
                         ; if vaddr < IntInf.toInt (!mem_base_addr)
                           then mem_base_addr := IntInf.fromInt vaddr
                           else ()
                         ; if vaddr + memsz > mem_end
                           then mem_size := IntInf.fromInt (vaddr + memsz - mem_end)
                           else ()
                         (* TODO: should check flags for executable segment *)
                         ; if dis then disassemble (#vaddr s) (#memsz s)
                           else ()
                       end)
                 else ( print ("Skipping segment ...\n")
                      ; Elf.printSegment s
                      )
             ) segms

fun match_symb (name : string) (s : Elf.symb) =
    case (#syname s) of
        NONE    => false
     |  SOME nm => Substring.string nm = name

fun set_tohost (tohost : Elf.symb option) =
    case tohost of
        NONE   =>
        print "L3RISCV: no tohost symbol found!\n"
     |  SOME s =>
        let val addr = Int.fromLarge (#syvalue s)
        in print ("L3RISCV: tohost mapped to 0x" ^ (hxi addr) ^ "\n")
         ; riscv.htif_tohost_addr := BitsN.fromInt(IntInf.fromInt addr, IntInf.fromInt 64)
        end

fun setupElf file dis =
    let val elf    = Elf.openElf file
        val hdr    = Elf.getHeader elf
        val segms  = Elf.getSegments elf hdr
        val sects  = Elf.getSections elf hdr
        val nsects = Elf.getNamedSections elf hdr sects
        val symbs  = Elf.getSymbols elf hdr nsects
        val pc     = if !boot then reset_addr else (LargeInt.toInt (#entry hdr))
        val tohost = List.find (match_symb "tohost") symbs
    in  set_tohost tohost
      ; initCores ( if (#class hdr) = Elf.BIT_32
                    then riscv.RV32 else riscv.RV64
                  , IntInf.fromInt pc
                  )
      ; print ("L3RISCV: pc set to 0x" ^ (hx64 (Word64.fromInt pc))
               ^ (if !boot then " [boot]\n" else " [elf]\n"))
      ; if !trace_elf
        then ( print "Loading elf file ...\n"
             ; Elf.printHeader hdr
             ; List.app Elf.printNamedSection nsects
             ; List.app Elf.printSymbol symbs
             )
        else ()
      ; be := (if (#endian hdr = Elf.BIG) then true else false)
      ; loadElf segms dis
      ; if !trace_elf
        then ( print ("\nMem base: " ^ (hxi64 (!mem_base_addr)))
             ; print ("\nMem size: " ^ (hxi64 (!mem_size))
                      ^ " (" ^ (IntInf.fmt StringCvt.DEC (!mem_size)) ^ ")\n")
             )
        else ()
    end

fun doElf cycles file dis =
    ( setupElf file dis
    ; if !check
      then loadChecker file
      else ()
    ; if dis
      then printLog ()
      else runWrapped cycles
    )

(* Tandem verification:
   server interface: verify against model *)

datatype VerifyMsg = InstrRetire | Reset | WriteMem | WriteGPR | WriteCSR | WriteFPR | WriteFSR | WritePC

fun typeOfMsg m =
    case m of 0 => SOME InstrRetire
            | 1 => SOME Reset
            | 2 => SOME WriteMem
            | 3 => SOME WriteGPR
            | 4 => SOME WriteCSR
            | 5 => SOME WriteFPR
            | 6 => SOME WriteFSR
            | 7 => SOME WritePC
            | _ => NONE

fun strOfMsg m =
    case m of SOME InstrRetire => "instr-retire"
            | SOME Reset       => "reset"
            | SOME WriteMem    => "write-mem"
            | SOME WriteGPR    => "write-gpr"
            | SOME WriteCSR    => "write-csr"
            | SOME WriteFPR    => "write-fpr"
            | SOME WriteFSR    => "write-fsr"
            | SOME WritePC     => "write-pc"
            | NONE             => "unknown"


fun doInstrRetire (exc, pc, addr, d1, d2, d3, fpd, v) =
    let fun toW64 bits      = Word64.fromInt (IntInf.toInt (BitsN.toUInt bits))
        val rpc             = toW64 (riscv.PC ())
        fun eqW64 a b       = Word64.compare (a, b) = EQUAL
        fun checkOpt ot v   = case ot of
                                  SOME b => eqW64 (toW64 b) v
                                | NONE   => true
        fun checkSubOpt optval optwidth v =
            case (optval, optwidth) of
                (NONE, _)           => true
              | (SOME b, NONE)      => eqW64 (toW64 b) v
              | (SOME b, SOME w)    => let val mask = mkMask64 w
                                       in  eqW64 (Word64.andb ((toW64 b), mask))
                                                 (Word64.andb (v,         mask))
                                       end
    in  verifierTrace (1, String.concat(["instr-retire: pc=", hx64 pc
                                         , " addr=", hx64 addr
                                         , " d1=", hx64 d1
                                         , " d2=", hx64 d2
                                         , " d3=", hx64 d3
                                         , " fpd=", hx64 fpd]))
      ; (riscv.Next () ; printLog (); print ("\n"))
        handle riscv.UNDEFINED s =>
               ( dumpRegisters (currentCore ())
               ; failExit ("UNDEFINED \"" ^ s ^ "\"\n")
               )
             | riscv.INTERNAL_ERROR s =>
               ( dumpRegisters (currentCore ())
               ; failExit ("INTERNAL_ERROR \"" ^ s ^ "\"\n")
               )
      ; let val delta   = riscv.Delta ()
            val exc_ok  = if (#exc_taken delta) then exc <> 0x0 else exc = 0x0
            val pc_ok   = eqW64 (toW64 (#pc delta))     pc
            val inst_ok = eqW64 (toW64 (#rinstr delta)) d3
            val addr_ok = checkOpt (#addr delta)    addr
            val d1_ok   = checkOpt (#data1 delta)   d1
            val fp_ok   = checkOpt (#fp_data delta) fpd
            val d2_ok   = checkSubOpt (#data2 delta) (#st_width delta) d2
            val all_ok  = (exc_ok andalso pc_ok andalso inst_ok andalso addr_ok
                           andalso d1_ok andalso d2_ok andalso fp_ok)
        in  if all_ok then 0
            else ( if exc_ok then ()
                   else verifierTrace (0, "Exception mis-match")
                 ; if pc_ok then ()
                   else verifierTrace (0, "PC mis-match")
                 ; if inst_ok orelse (#fetch_exc delta) then ()
                   else verifierTrace (0, "Instruction mis-match")
                 ; if addr_ok then ()
                   else verifierTrace (0, "Address mis-match")
                 ; if d1_ok then ()
                   else verifierTrace (0, "Data1 mis-match")
                 ; if d2_ok then ()
                   else verifierTrace (0, "Data2 mis-match")
                 ; if fp_ok then ()
                   else verifierTrace (0, "FP mis-match")
                 ; dumpRegisters (currentCore ())
                 ; failExit ("VERIFICATION_FAILURE")
                 )
        end
    end

fun initModel () =
    ()

(* Command line interface *)

fun printUsage () =
    print
        ("\nRISCV emulator (based on an L3 specification).\n\
          \http://www.cl.cam.ac.uk/~acjf3/l3\n\n\
          \usage: " ^ OS.Path.file (CommandLine.name ()) ^ " [arguments] file\n\n\
          \Arguments:\n\
          \  --dis    <bool>      only disassemble loaded code\n\
          \  --cycles <number>    upper bound on instruction cycles\n\
          \  --trace  <level>     verbosity level (0 default, 2 maximum)\n\
          \  --multi  <#cores>    number of cores (1 default)\n\
          \  --check  <bool>      check execution against external verifier\n\
          \  --boot   <bool>      set starting pc to reset address x1000 (false default)\n\
          \  -h or --help         print this message\n\n")

fun getNumber s =
    case IntExtra.fromString s of
        SOME n => n
      | NONE   => failExit ("Bad number: " ^ s)

fun getBool s =
    case Bool.fromString s of
        SOME b => b
     |  NONE   => failExit ("Bad bool: " ^ s)

fun getArguments () =
    List.map
        (fn "-c" => "--cycles"
        | "-t"   => "--trace"
        | "-d"   => "--dis"
        | "-h"   => "--help"
        | "-k"   => "--check"
        | "-m"   => "--multi"
        | "-v"   => "--verifier"
        | "-b"   => "--boot"
        | s      => s
        ) (CommandLine.arguments ())

fun processOption (s: string) =
    let fun loop acc =
            fn a :: b :: r =>
               if a = s
               then (SOME b, List.rev acc @ r)
               else loop (a :: acc) (b :: r)
          | r => (NONE, List.rev acc @ r)
    in  loop []
    end

fun main_wrapped () =
    case getArguments () of
        ["--help"] => printUsage ()
      | l =>
        let val (c, l) = processOption "--cycles"   l
            val (t, l) = processOption "--trace"    l
            val (d, l) = processOption "--dis"      l
            val (k, l) = processOption "--check"    l
            val (m, l) = processOption "--multi"    l
            val (v, l) = processOption "--verifier" l
            val (b, l) = processOption "--boot"     l

            val c = Option.getOpt (Option.map getNumber c, ~1)
            val d = Option.getOpt (Option.map getBool d, !trace_elf)
            val t = Option.getOpt (Option.map getNumber t,
                                   (IntInf.fromInt (!trace_lvl)))
            val m = Option.getOpt (Option.map getNumber m, 1)
            val k = Option.getOpt (Option.map getBool k, !check)
            val v = Option.getOpt (Option.map getBool v, !verifier_mode)
            val b = Option.getOpt (Option.map getBool b, !boot)

            val () = trace_lvl      := Int.max (0, IntInf.toInt t)
            val () = check          := k
            val () = trace_elf      := d
            val () = verifier_mode  := v
            val () = boot           := b

        in  if List.null l andalso not (!verifier_mode)
            then printUsage ()
            else ( initPlatform (m)
                 ; if !verifier_mode
                   then initModel ()
                   else doElf (IntInf.toInt c) (List.hd l) d
                 )
        end

fun main () =
    main_wrapped ()
    handle e => print ("Exception error:" ^ (exnMessage e) ^ "\n")