unit CompScintEdit;

{
  Inno Setup
  Copyright (C) 1997-2024 Jordan Russell
  Portions by Martijn Laan
  For conditions of distribution and use, see LICENSE.TXT.

  Compiler IDE's TScintEdit
}

interface

uses
  Windows, Graphics, Classes, Generics.Collections, ScintInt, ScintEdit, ModernColors;

const
  { Memo marker numbers }
  mmIconHasEntry = 0;        { grey dot }
  mmIconEntryProcessed = 1;  { green dot }
  mmIconBreakpoint = 2;      { stop sign }
  mmIconBreakpointGood = 3;  { stop sign + check }
  mmIconBreakpointBad = 4;   { stop sign + X }
  mmIconsMask = $1F;

  mmLineError = 10;          { maroon line highlight }
  mmLineBreakpointBad = 11;  { ugly olive line highlight }
  mmLineStep = 12;           { blue line highlight }
  mmIconStep = 13;           { blue arrow }
  mmIconBreakpointStep = 14; { blue arrow on top of a stop sign + check }

  { Memo indicator numbers - Note: inSquiggly and inPendingSquiggly are 0 and 1
    in ScintStylerInnoSetup and must be first and second here. Also note: even
    though inSquiggly and inPendingSquiggly are exclusive we still need 2 indicators
    (instead of 1 indicator with 2 values) because inPendingSquiggly is always
    hidden and in inSquiggly is not. }
  inSquiggly = INDICATOR_CONTAINER;
  inPendingSquiggly = INDICATOR_CONTAINER+1;
  inWordAtCursorOccurrence = INDICATOR_CONTAINER+2;
  inSelTextOccurrence = INDICATOR_CONTAINER+3;
  inMax = inSelTextOccurrence;

  { Just some invalid value used to indicate an unknown/uninitialized compiler FileIndex value }
  UnknownCompilerFileIndex = -2;

type
  TLineState = (lnUnknown, lnHasEntry, lnEntryProcessed);
  PLineStateArray = ^TLineStateArray;
  TLineStateArray = array[0..0] of TLineState;
  TSaveEncoding = (seAuto, seUTF8WithBOM, seUTF8WithoutBOM);
  TCompScintIndicatorNumber = 0..inMax;

  TCompScintEdit = class(TScintEdit)
  private
    FTheme: TTheme;
    FOpeningFile: Boolean;
    FUsed: Boolean; { The IDE only shows 1 memo at a time so can't use .Visible to check if a memo is used }
    FIndicatorCount: array[TCompScintIndicatorNumber] of Integer;
    FIndicatorHash: array[TCompScintIndicatorNumber] of String;
  protected
    procedure CreateWnd; override;
  public
    property Theme: TTheme read FTheme write FTheme;
    property OpeningFile: Boolean read FOpeningFile write FOpeningFile;
    property Used: Boolean read FUsed write FUsed;
    procedure UpdateIndicators(const Ranges: TScintRangeList;
      const IndicatorNumber: TCompScintIndicatorNumber);
    procedure UpdateMarginsAndSquigglyWidths(const IconMarkersWidth,
      BaseChangeHistoryWidth, FolderMarkersWidth, LeftBlankMarginWidth,
      RightBlankMarginWidth, SquigglyWidth: Integer);
    procedure UpdateThemeColorsAndStyleAttributes;
  end;

  TCompScintFileEdit = class(TCompScintEdit)
  private
    FBreakPoints: TList<Integer>;
    FCompilerFileIndex: Integer;
    FFilename: String;
    FFileLastWriteTime: TFileTime;
    FSaveEncoding: TSaveEncoding;
  public
    ErrorLine, ErrorCaretPosition: Integer;
    StepLine: Integer;
    LineState: PLineStateArray;
    LineStateCapacity, LineStateCount: Integer;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property BreakPoints: TList<Integer> read FBreakPoints;
    property Filename: String read FFileName write FFilename;
    property CompilerFileIndex: Integer read FCompilerFileIndex write FCompilerFileIndex;
    property FileLastWriteTime: TFileTime read FFileLastWriteTime write FFileLastWriteTime;
    property SaveEncoding: TSaveEncoding read FSaveEncoding write FSaveEncoding;
  end;

  TCompScintEditNavItem = record
    Memo: TCompScintEdit;
    Line, Column, VirtualSpace: Integer;
    constructor Create(const AMemo: TCompScintEdit);
    function EqualMemoAndLine(const ANavItem: TCompScintEditNavItem): Boolean;
    procedure Invalidate;
    function Valid: Boolean;
  end;

  { Not using TStack since it lacks a way the keep a maximum amount of items by discarding the oldest }
  TCompScintEditNavStack = class(TList<TCompScintEditNavItem>)
  public
    function LinesDeleted(const AMemo: TCompScintEdit; const FirstLine, LineCount: Integer): Boolean;
    procedure LinesInserted(const AMemo: TCompScintEdit; const FirstLine, LineCount: Integer);
    procedure Optimize;
    function RemoveMemo(const AMemo: TCompScintEdit): Boolean;
    function RemoveMemoBadLines(const AMemo: TCompScintEdit): Boolean;
  end;

  TCompScintEditNavStacks = class
  private
    FBackNavStack: TCompScintEditNavStack;
    FForwardNavStack: TCompScintEditNavStack;
  public
    constructor Create;
    destructor Destroy; override;
    function AddNewBackForJump(const OldNavItem, NewNavItem: TCompScintEditNavItem): Boolean;
    procedure Clear;
    procedure Limit;
    function LinesDeleted(const AMemo: TCompScintEdit; const FirstLine, LineCount: Integer): Boolean;
    procedure LinesInserted(const AMemo: TCompScintEdit; const FirstLine, LineCount: Integer);
    function RemoveMemo(const AMemo: TCompScintEdit): Boolean;
    function RemoveMemoBadLines(const AMemo: TCompScintEdit): Boolean;
    property Back: TCompScintEditNavStack read FBackNavStack;
    property Forward: TCompScintEditNavStack read FForwardNavStack;
  end;

implementation

uses
  MD5;
  
{ TCompScintEdit }

procedure TCompScintEdit.CreateWnd;
const
  SC_MARK_BACKFORE = 3030;  { new marker type added in Inno Setup's Scintilla build }
begin
  inherited;

  { Some notes about future Scintilla versions:
    -Does it at some point become possible to change mouse shortcut Ctrl+Click
     to Alt+Click? And Alt+Shift+Drag instead of Alt+Drag for rect select?
    -What about using Calltips and SCN_DWELLSTART to show variable evalutions?
    -Add folding support?
    -3.6.6: Investigate SCFIND_CXX11REGEX: C++ 11 <regex> support built by default.
            Can be disabled by defining NO_CXX11_REGEX. Good (?) overview at:
            https://cplusplus.com/reference/regex/ECMAScript/
    -5.2.3: "Applications should move to SCI_GETTEXTRANGEFULL, SCI_FINDTEXTFULL,
            and SCI_FORMATRANGEFULL from their predecessors as they will be
            deprecated." So our use of SCI_GETTEXTRANGE and SCI_FORMATRANGE needs
            to be updated but that also means we should do many more changes to
            replace all the Integer positions with a 'TScintPosition = type
            NativeInt'. Does not actually change anything until there's a
            64-bit build...
            Later SCI_GETSTYLEDTEXTFULL was also added but we don't use it at
            the time of writing. }

  Call(SCI_SETCARETWIDTH, 2, 0);
  Call(SCI_AUTOCSETAUTOHIDE, 0, 0);
  Call(SCI_AUTOCSETCANCELATSTART, 0, 0);
  Call(SCI_AUTOCSETDROPRESTOFWORD, 1, 0);
  Call(SCI_AUTOCSETIGNORECASE, 1, 0);
  Call(SCI_AUTOCSETMAXHEIGHT, 12, 0);
  Call(SCI_AUTOCSETMULTI, SC_MULTIAUTOC_EACH, 0);

  Call(SCI_SETMULTIPLESELECTION, 1, 0);
  Call(SCI_SETADDITIONALSELECTIONTYPING, 1, 0);
  Call(SCI_SETMULTIPASTE, SC_MULTIPASTE_EACH, 0);

  Call(SCI_ASSIGNCMDKEY, Ord('Z') or ((SCMOD_SHIFT or SCMOD_CTRL) shl 16), SCI_REDO);
  Call(SCI_ASSIGNCMDKEY, SCK_UP or (SCMOD_ALT shl 16), SCI_MOVESELECTEDLINESUP);
  Call(SCI_ASSIGNCMDKEY, SCK_DOWN or (SCMOD_ALT shl 16), SCI_MOVESELECTEDLINESDOWN);

  Call(SCI_SETSCROLLWIDTH, 1024 * CallStr(SCI_TEXTWIDTH, 0, 'X'), 0);

  Call(SCI_INDICSETSTYLE, inSquiggly, INDIC_SQUIGGLE); { Overwritten by TCompForm.SyncEditorOptions }
  Call(SCI_INDICSETFORE, inSquiggly, clRed); { May be overwritten by UpdateThemeColorsAndStyleAttributes }
  Call(SCI_INDICSETSTYLE, inPendingSquiggly, INDIC_HIDDEN);

  Call(SCI_INDICSETSTYLE, inWordAtCursorOccurrence, INDIC_STRAIGHTBOX);
  Call(SCI_INDICSETFORE, inWordAtCursorOccurrence, clSilver); { May be overwritten by UpdateThemeColorsAndStyleAttributes }
  Call(SCI_INDICSETALPHA, inWordAtCursorOccurrence, SC_ALPHA_OPAQUE);
  Call(SCI_INDICSETOUTLINEALPHA, inWordAtCursorOccurrence, SC_ALPHA_OPAQUE);
  Call(SCI_INDICSETUNDER, inWordAtCursorOccurrence, 1);

  Call(SCI_INDICSETSTYLE, inSelTextOccurrence, INDIC_STRAIGHTBOX);
  Call(SCI_INDICSETFORE, inSelTextOccurrence, clSilver); { May be overwritten by UpdateThemeColorsAndStyleAttributes }
  Call(SCI_INDICSETALPHA, inSelTextOccurrence, SC_ALPHA_OPAQUE);
  Call(SCI_INDICSETOUTLINEALPHA, inSelTextOccurrence, SC_ALPHA_OPAQUE);
  Call(SCI_INDICSETUNDER, inSelTextOccurrence, 1);

  { Set up the gutter column with line numbers - avoid Scintilla's 'reverse arrow'
    cursor which is not a standard Windows cursor so is just confusing, especially
    because the line numbers are clickable to select lines. Note: width of the
    column is set up for us by TScintEdit.UpdateLineNumbersWidth. }
  Call(SCI_SETMARGINCURSORN, 0, SC_CURSORARROW);

  { Set up the gutter column with breakpoint etc symbols }
  Call(SCI_SETMARGINTYPEN, 1, SC_MARGIN_SYMBOL);
  Call(SCI_SETMARGINMASKN, 1, mmIconsMask);
  Call(SCI_SETMARGINSENSITIVEN, 1, 1); { Makes it send SCN_MARGIN(RIGHT)CLICK instead of selecting lines }
  Call(SCI_SETMARGINCURSORN, 1, SC_CURSORARROW);

  { Set up the gutter column with change history. Note: width of the column is
    set up for us by TScintEdit.UpdateChangeHistoryWidth. Also see
    https://scintilla.org/ChangeHistory.html }
  Call(SCI_SETMARGINTYPEN, 2, SC_MARGIN_SYMBOL);
  Call(SCI_SETMARGINMASKN, 2, not (SC_MASK_FOLDERS or mmIconsMask));
  Call(SCI_SETMARGINCURSORN, 2, SC_CURSORARROW);

  Call(SCI_SETMARGINTYPEN, 3, SC_MARGIN_SYMBOL);
  Call(SCI_SETMARGINMASKN, 3, LPARAM(SC_MASK_FOLDERS));
  Call(SCI_SETMARGINCURSORN, 3, SC_CURSORARROW);
  Call(SCI_SETMARGINWIDTHN, 3, 16);
  Call(SCI_SETMARGINSENSITIVEN, 3, 1);
  Call(SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW or SC_AUTOMATICFOLD_CLICK or SC_AUTOMATICFOLD_CHANGE, 0);

  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPEN, SC_MARK_ARROWDOWN);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDER, SC_MARK_ARROW);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDERSUB, SC_MARK_EMPTY);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDERTAIL, SC_MARK_EMPTY);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDEREND, SC_MARK_EMPTY);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPENMID, SC_MARK_EMPTY);
  Call(SCI_MARKERDEFINE, SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_EMPTY);

  Call(SCI_MARKERDEFINE, mmLineError, SC_MARK_BACKFORE);
  Call(SCI_MARKERSETFORE, mmLineError, clWhite);
  Call(SCI_MARKERSETBACK, mmLineError, clMaroon);
  Call(SCI_MARKERDEFINE, mmLineBreakpointBad, SC_MARK_BACKFORE);
  Call(SCI_MARKERSETFORE, mmLineBreakpointBad, clLime);
  Call(SCI_MARKERSETBACK, mmLineBreakpointBad, clOlive);
  Call(SCI_MARKERDEFINE, mmLineStep, SC_MARK_BACKFORE);
  Call(SCI_MARKERSETFORE, mmLineStep, clWhite);
  Call(SCI_MARKERSETBACK, mmLineStep, clBlue); { May be overwritten by UpdateThemeColorsAndStyleAttributes }
end;

procedure TCompScintEdit.UpdateIndicators(const Ranges: TScintRangeList;
  const IndicatorNumber: TCompScintIndicatorNumber);

  function HashRanges(const Ranges: TScintRangeList): String;
  begin
    if Ranges.Count > 0 then begin
      var Context: TMD5Context;
      MD5Init(Context);
      for var Range in Ranges do
        MD5Update(Context, Range, SizeOf(Range));
      Result := MD5DigestToString(MD5Final(Context));
    end else
      Result := '';
  end;

begin
  var NewCount := Ranges.Count;
  var NewHash: String;
  var GotNewHash := False;

  var Update := NewCount <> FIndicatorCount[IndicatorNumber];
  if not Update and (NewCount <> 0) then begin
    NewHash := HashRanges(Ranges);
    GotNewHash := True;
    Update := NewHash <> FIndicatorHash[IndicatorNumber];
  end;

  if Update then begin
    Self.ClearIndicators(IndicatorNumber);
    for var Range in Ranges do
      Self.SetIndicators(Range.StartPos, Range.EndPos, IndicatorNumber, True);

    if not GotNewHash then
      NewHash := HashRanges(Ranges);

    FIndicatorCount[IndicatorNumber] := NewCount;
    FIndicatorHash[IndicatorNumber] := NewHash;
  end;
end;

procedure TCompScintEdit.UpdateMarginsAndSquigglyWidths(const IconMarkersWidth,
  BaseChangeHistoryWidth, FolderMarkersWidth, LeftBlankMarginWidth,
  RightBlankMarginWidth, SquigglyWidth: Integer);
begin
  Call(SCI_SETMARGINWIDTHN, 1, IconMarkersWidth);

  var ChangeHistoryWidth: Integer;
  if ChangeHistory then
    ChangeHistoryWidth := BaseChangeHistoryWidth
  else
    ChangeHistoryWidth := 0; { Current this is just the preprocessor output memo }
  Call(SCI_SETMARGINWIDTHN, 2, ChangeHistoryWidth);

  Call(SCI_SETMARGINWIDTHN, 3, FolderMarkersWidth);

  { Note: the first parameter is unused so the value '0' doesn't mean anything below }
  Call(SCI_SETMARGINLEFT, 0, LeftBlankMarginWidth);
  Call(SCI_SETMARGINRIGHT, 0, RightBlankMarginWidth);

  Call(SCI_INDICSETSTROKEWIDTH, inSquiggly, SquigglyWidth);
end;

procedure TCompScintEdit.UpdateThemeColorsAndStyleAttributes;
begin
  if FTheme <> nil then begin
    Font.Color := FTheme.Colors[tcFore];
    Color := FTheme.Colors[tcBack];

    var SelBackColor := FTheme.Colors[tcSelBack];
    Call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_BACK, SelBackColor);
    Call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_ADDITIONAL_BACK, SelBackColor);

    var SelInactiveBackColor := FTheme.Colors[tcSelInactiveBack];
    Call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_SECONDARY_BACK, SelInactiveBackColor);
    Call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_INACTIVE_BACK, SelInactiveBackColor);
    Call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_BACK, SelInactiveBackColor);

    Call(SCI_SETFOLDMARGINCOLOUR, 1, FTheme.Colors[tcMarginBack]);
    Call(SCI_SETFOLDMARGINHICOLOUR, 1, FTheme.Colors[tcMarginBack]);

    Call(SCI_INDICSETFORE, inSquiggly, FTheme.Colors[tcRed]);
    Call(SCI_INDICSETFORE, inWordAtCursorOccurrence, FTheme.Colors[tcWordAtCursorOccurrenceBack]);
    Call(SCI_INDICSETFORE, inSelTextOccurrence, FTheme.Colors[tcSelTextOccurrenceBack]);
    
    Call(SCI_MARKERSETBACK, mmLineStep, FTheme.Colors[tcBlue]);
    
    Call(SCI_MARKERSETFORE, SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN, FTheme.Colors[tcBlue]); { To reproduce: open a file, press enter, save, undo }
    Call(SCI_MARKERSETBACK, SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN, FTheme.Colors[tcBlue]);
    Call(SCI_MARKERSETFORE, SC_MARKNUM_HISTORY_SAVED, FTheme.Colors[tcGreen]);
    Call(SCI_MARKERSETBACK, SC_MARKNUM_HISTORY_SAVED, FTheme.Colors[tcGreen]);
    Call(SCI_MARKERSETFORE, SC_MARKNUM_HISTORY_MODIFIED, FTheme.Colors[tcReallyOrange]);
    Call(SCI_MARKERSETBACK, SC_MARKNUM_HISTORY_MODIFIED, FTheme.Colors[tcReallyOrange]);
    Call(SCI_MARKERSETFORE, SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED, FTheme.Colors[tcTeal]); { To reproduce: ??? - sometimes get it but not sure how to do this with minimal steps }
    Call(SCI_MARKERSETBACK, SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED, FTheme.Colors[tcTeal]);
  end;
  UpdateStyleAttributes;
end;

{ TCompScintFileEdit }

constructor TCompScintFileEdit.Create;
begin
  inherited;
  FBreakPoints := TList<Integer>.Create;
end;

destructor TCompScintFileEdit.Destroy;
begin
  FBreakPoints.Free;
  inherited;
end;

{ TCompScintEditNavItem }

constructor TCompScintEditNavItem.Create(const AMemo: TCompScintEdit);
begin
  Memo := AMemo;
  Line := AMemo.CaretLine;
  Column := AMemo.CaretColumn;
  VirtualSpace := AMemo.CaretVirtualSpace;
end;

function TCompScintEditNavItem.EqualMemoAndLine(
  const ANavItem: TCompScintEditNavItem): Boolean;
begin
  Result := (Memo = ANavItem.Memo) and (Line = ANavItem.Line);
end;

procedure TCompScintEditNavItem.Invalidate;
begin
  Memo := nil;
end;

function TCompScintEditNavItem.Valid: Boolean;
begin
  Result := (Memo <> nil) and (Line < Memo.Lines.Count); { Line check: see MemoLinesDeleted and RemoveMemoBadLinesFromNav }
end;

{ TCompScintEditNavStack }

function TCompScintEditNavStack.LinesDeleted(const AMemo: TCompScintEdit;
  const FirstLine, LineCount: Integer): Boolean;
begin
  Result := False;
  for var I := Count-1 downto 0 do begin
    var NavItem := Items[I];
    if NavItem.Memo = AMemo then begin
      var Line := NavItem.Line;
      if Line >= FirstLine then begin
        if Line < FirstLine + LineCount then begin
          Delete(I);
          Result := True;
        end else begin
          NavItem.Line := Line - LineCount;
          Items[I] := NavItem;
        end;
      end;
    end;
  end;
  if Result then
    Optimize;
end;

procedure TCompScintEditNavStack.LinesInserted(const AMemo: TCompScintEdit;
  const FirstLine, LineCount: Integer);
begin
  for var I := 0 to Count-1 do begin
    var NavItem := Items[I];
    if NavItem.Memo = AMemo then begin
      var Line := NavItem.Line;
      if Line >= FirstLine then begin
        NavItem.Line := Line + LineCount;
        Items[I] := NavItem;
      end;
    end;
  end;
end;

procedure TCompScintEditNavStack.Optimize;
begin
  { Turn two entries for the same memo and line which are next to each other
    into one entry, ignoring column differences (like Visual Studio 2022)
    Note: doesn't yet look at CompForm's FCurrentNavItem to see if a stack's top
    item is the same so it doesnt optimize that situation atm }
  for var I := Count-1 downto 1 do
    if Items[I].EqualMemoAndLine(Items[I-1]) then
      Delete(I);
end;

function TCompScintEditNavStack.RemoveMemo(
  const AMemo: TCompScintEdit): Boolean;
begin
  Result := False;
  for var I := Count-1 downto 0 do begin
    if Items[I].Memo = AMemo then begin
      Delete(I);
      Result := True;
    end;
  end;
  if Result then
    Optimize;
end;

function TCompScintEditNavStack.RemoveMemoBadLines(
  const AMemo: TCompScintEdit): Boolean;
begin
  Result := False;
  var LastGoodLine := AMemo.Lines.Count-1;
  for var I := Count-1 downto 0 do begin
    if (Items[I].Memo = AMemo) and (Items[I].Line > LastGoodLine) then begin
      Delete(I);
      Result := True;
    end;
  end;
  if Result then
    Optimize;
end;

{ TCompScintEditNavStacks }

constructor TCompScintEditNavStacks.Create;
begin
  inherited;
  FBackNavStack := TCompScintEditNavStack.Create;
  FForwardNavStack := TCompScintEditNavStack.Create;
end;

destructor TCompScintEditNavStacks.Destroy;
begin
  FForwardNavStack.Free;
  FBackNavStack.Free;
  inherited;
end;

function TCompScintEditNavStacks.AddNewBackForJump(const OldNavItem,
  NewNavItem: TCompScintEditNavItem): Boolean;
begin
  { Want a new item when changing tabs or moving at least 11 lines at once,
    similar to Visual Studio 2022, see:
    https://learn.microsoft.com/en-us/archive/blogs/zainnab/navigate-backward-and-navigate-forward
    Note: not doing the other stuff listed in the article atm }
  Result := (OldNavItem.Memo <> NewNavItem.Memo) or
            (Abs(OldNavItem.Line - NewNavItem.Line) >= 11);
  if Result then begin
    FBackNavStack.Add(OldNavItem);
    Limit;
  end;
end;

procedure TCompScintEditNavStacks.Clear;
begin
  FBackNavStack.Clear;
  FForwardNavStack.Clear;
end;

procedure TCompScintEditNavStacks.Limit;
begin
  { The dropdown showing both stacks + the current nav item should show at most
    16 items just like Visual Studio 2022 }
  if FBackNavStack.Count + FForwardNavStack.Count >= 15 then
    FBackNavStack.Delete(0);
end;

function TCompScintEditNavStacks.LinesDeleted(const AMemo: TCompScintEdit;
  const FirstLine, LineCount: Integer): Boolean;
begin
  Result := FBackNavStack.LinesDeleted(AMemo, FirstLine, LineCount);
  Result := FForwardNavStack.LinesDeleted(AMemo, FirstLine, LineCount) or Result;
end;

procedure TCompScintEditNavStacks.LinesInserted(const AMemo: TCompScintEdit;
  const FirstLine, LineCount: Integer);
begin
  FBackNavStack.LinesInserted(AMemo, FirstLine, LineCount);
  FForwardNavStack.LinesInserted(AMemo, FirstLine, LineCount);
end;

function TCompScintEditNavStacks.RemoveMemo(
  const AMemo: TCompScintEdit): Boolean;
begin
  Result := FBackNavStack.RemoveMemo(AMemo);
  Result := FForwardNavStack.RemoveMemo(AMemo) or Result;
end;

function TCompScintEditNavStacks.RemoveMemoBadLines(
  const AMemo: TCompScintEdit): Boolean;
begin
  Result := FBackNavStack.RemoveMemoBadLines(AMemo);
  Result := FForwardNavStack.RemoveMemoBadLines(AMemo) or Result;
end;

end.